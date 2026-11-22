"""Verify a RallyCapture export without either app. Optionally extract a labelled IMU window."""
import argparse
import csv
import hashlib
import json
from pathlib import Path


def inspect(root, trial, out):
    def read_json(name):
        return json.loads((root / name).read_text(encoding="utf-8"))

    def read_rows(name):
        with (root / name).open(encoding="utf-8", newline="") as stream:
            return list(csv.DictReader(stream))

    checks = read_json("checksums.json")
    for name in ("manifest.json", "trials_index.csv", "samples.csv"):
        if name not in checks:
            raise ValueError(f"missing checksum for {name}")
    for name, expected in checks.items():
        if Path(name).name != name:
            raise ValueError("unexpected nested file in manifest")
        with (root / name).open("rb") as stream:
            actual = hashlib.file_digest(stream, "sha256").hexdigest()
        if actual != expected:
            raise ValueError(f"checksum mismatch: {name}")
    info = read_json("manifest.json")
    imu = read_rows("samples.csv")
    if any(int(row["seq"]) != i for i, row in enumerate(imu)):
        raise ValueError("sample sequence mismatch")
    index = read_rows("trials_index.csv")
    frames = read_rows("frames.csv") if "frames.csv" in checks else []
    for row in index:
        if row["session_id"].lower() != info["id"].lower():
            raise ValueError("trial belongs to a different session")
        if row["quality"] == "unaligned":
            continue
        a, b = int(row["seq_first"]), int(row["seq_last"])
        if not (0 <= a <= b < len(imu)):
            raise ValueError("invalid sample range")
        if row["video_file"] not in checks or row["imu_file"] not in checks:
            raise ValueError("missing referenced media")
    print(f"{info['id']} ({info['state']}): {len(imu)} samples, {len(frames)} frames, {len(index)} labels")
    if trial:
        match = next((row for row in index if row["trial_id"] == trial), None)
        if match is None or match["quality"] == "unaligned":
            raise ValueError("trial missing or synchronization unavailable")
        print(f"{match['actual_label']}: {match['video_file']} [{match['video_start_s']}, {match['video_end_s']}] seconds")
        if out:
            with out.open("x", newline="", encoding="utf-8") as f:
                writer = csv.DictWriter(f, fieldnames=imu[0].keys())
                writer.writeheader()
                writer.writerows(imu[int(match["seq_first"]):int(match["seq_last"]) + 1])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folder", type=Path)
    parser.add_argument("--trial")
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    if args.out and not args.trial:
        parser.error("--out requires --trial")
    try:
        inspect(args.folder, args.trial, args.out)
    except (OSError, ValueError, KeyError) as exc:
        parser.exit(1, f"{exc}\n")
