"""Replay reviewed captures and exported match CSVs. Example paths in --help."""
import argparse
import csv
import json
import subprocess
import tempfile
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
COLUMNS = "t_phone rx ry rz ax_g ay_g az_g gx gy gz".split()
HITS = {"上挑", "下挥", "平抽", "方向未定"}


def read_csv(path):
    with path.open(encoding="utf-8-sig", newline="") as stream:
        return list(csv.DictReader(stream))


def replay(engine, session, rows, states=None, profile=None):
    states = states or []
    first = states[0] if states else {}
    lines = ["\t".join(("session", session, str(int(first.get("leftHand") == "True")),
                        str(int(first.get("lightSwing") == "True"))))]
    index = 0
    serving = False
    receiving = False
    for row in rows:
        while index < len(states) and float(states[index]["phoneTime"]) <= float(row["t_phone"]):
            snapshot = states[index]
            serving = snapshot["phase"] == "serve" and ("我方" in snapshot.get("message", "") or
                      snapshot.get("mode", "").startswith("场景采集/我方发球/"))
            receiving = states[index]["hitWindowOpen"] == "True"
            index += 1
        lines.append("\t".join([row[k] for k in COLUMNS] + [str(int(receiving)), str(int(serving))]))
    command = [engine, ROOT / "Clients/iOS/Resources/SwingCurves.json"]
    if profile:
        command.append(profile)
    output = subprocess.run(command,
                            input="\n".join(lines), text=True, capture_output=True, check=True)
    events = []
    for line in output.stdout.splitlines()[1:]:
        peak, emitted, decision, label, power = line.split("\t")
        events.append(dict(peak=float(peak), delay_ms=round(1000*(float(emitted)-float(peak))),
                           decision=decision, label=label, power=float(power)))
    return events


def score_windows(events, windows):
    """Only score hand-reviewed, non-overlapping windows, including idle footage."""
    results = []
    last_end = float("-inf")
    for window in sorted(windows, key=lambda w: float(w["start"])):
        start, end = float(window["start"]), float(window["end"])
        if start >= end or start < last_end:
            raise ValueError("Reviewed windows must have a positive duration and cannot overlap")
        last_end = end
        hits = [e for e in events if start <= e["peak"] < end and e["decision"] in HITS]
        expected = window["expected"]
        outputs = [e["label"] or e["decision"] for e in hits]
        if expected == "背景":
            result = "误触" if outputs else "正确"
        elif not outputs:
            result = "漏拍"
        elif len(outputs) > 1:
            result = "重复触发"
        else:
            result = "正确" if expected == outputs[0] else "错类"
        results.append(dict(start=start, end=end, expected=expected, outputs=outputs, result=result))
    return results


def evaluate(engine, args):
    rows = json.loads(args.examples.read_text())
    trials = []
    stress = []
    train_ids = {r["session"] for r in rows if r["split"] == "train"}
    test_ids = {r["session"] for r in rows if r["split"] == "test"}
    if train_ids & test_ids:
        raise ValueError("Training and test sessions overlap")
    for row in rows:
        if row.get("source") not in {"人工复核", "录像抽帧复核"}:
            continue
        samples = read_csv(args.root / row["session"] / "samples.csv")
        events = replay(engine, row["session"], samples)
        nearby = [e for e in events if abs(e["peak"] - row["peak"]) <= .15]
        hits = [e for e in nearby if e["decision"] in HITS]
        hit = min(hits, key=lambda e: abs(e["peak"] - row["peak"]), default={})
        trials.append(dict(session=row["session"], split=row["split"], expected=row["label"],
                           detected=len(hits), matched=hit.get("label") == row["label"],
                           output=hit.get("label") or hit.get("decision"), nearby=nearby))
        if args.stress and row["split"] == "test":
            # Same path traversed at a different speed: angular velocity scales
            # linearly and linear acceleration quadratically. Preserve gravity.
            for speed in (.8, 1.2):
                for stride in (1, 2):
                    transformed = []
                    for sample in samples[::stride]:
                        frame = sample.copy()
                        frame["t_phone"] = str(row["peak"] + (float(sample["t_phone"]) - row["peak"]) / speed)
                        for k in COLUMNS[1:7]:
                            frame[k] = str(float(sample[k]) * (speed if k.startswith("r") else speed**2))
                        transformed.append(frame)
                    variants = replay(engine, row["session"], transformed)
                    hits = [e for e in variants if e["decision"] in HITS and abs(e["peak"]-row["peak"]) <= .15]
                    nearest = min(hits, key=lambda e: abs(e["peak"]-row["peak"]), default={})
                    stress.append(dict(session=row["session"], speed=speed, stride=stride, expected=row["label"],
                                       detected=len(hits), exact=nearest.get("label") == row["label"]))
    if not trials:
        raise ValueError("No reviewed swings in examples.json")
    results = {}
    for split in sorted({t["split"] for t in trials}):
        group = [t for t in trials if t["split"] == split]
        results[split] = dict(total=len(group), detected=sum(bool(t["detected"]) for t in group),
                              exact=sum(t["matched"] for t in group),
                              extra_near_peak=sum(max(0, t["detected"]-1) for t in group))
    matches = []
    annotations = read_csv(args.match_labels) if args.match_labels else []
    unknown = {w["session"] for w in annotations} - {folder.parent.name for folder in args.match}
    if unknown:
        raise ValueError(f"Missing --match directory for {sorted(unknown)}")
    for folder in args.match:
        states = sorted(read_csv(folder/"states.csv"), key=lambda r: float(r["phoneTime"]))
        events = replay(engine, folder.parent.name, read_csv(folder/"motion.csv"), states, args.match_profile)
        logged = read_csv(folder/"events.csv")
        matches.append(dict(session=folder.parent.name,
                            recorded=dict(Counter(e["text"] for e in logged if e["kind"] == "candidate")),
                            replay=dict(Counter(e["decision"] for e in events)), events=events,
                            reviewed=score_windows(events, [w for w in annotations
                                                           if w["session"] == folder.parent.name])))
    return dict(summary=results, trials=trials, stress=stress, matches=matches,
                match_profile=str(args.match_profile or "无个人校准"),
                tolerance_ms=150)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path, help="动作采集 directory containing session samples.csv")
    parser.add_argument("examples", type=Path, help="reviewed training run's examples.json")
    parser.add_argument("--match", type=Path, action="append", default=[], help="match 分析 directory (repeatable)")
    parser.add_argument("--stress", action="store_true", help="Replay held captures at 0.8x/1.2x speed and full/half sampling")
    parser.add_argument("--match-labels", type=Path, help="Reviewed CSV: session,start,end,expected; phone clock in seconds")
    parser.add_argument("--match-profile", type=Path, help="Optional exported SwingCoach.Profile for match playback")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as temp:
        engine = Path(temp)/"court"
        subprocess.run(["swiftc", "-O", "Clients/iOS/Game/Rally.swift", "Clients/iOS/Motion/SwingCurveModel.swift",
                        "Clients/iOS/Motion/SwingCoach.swift", "Tools/ReplayCourt.swift", "-o", engine],
                       cwd=ROOT, check=True)
        report = evaluate(engine, args)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print(report["summary"])


if __name__ == "__main__":
    main()
