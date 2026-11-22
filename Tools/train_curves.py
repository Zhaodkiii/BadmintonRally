"""Build versioned, peak-aligned IMU prototypes from RallyCapture sessions."""
import argparse
import csv
import hashlib
import json
import os
import tempfile
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np

CHANNELS = ["rx", "ry", "rz", "ax_g", "ay_g", "az_g"]
LABELS = set("上挑 下挥 平抽 头顶高远 正手扣杀 吊球 网前放网 反手短发 反手挑球 背景 正手高远发球 正手短发球 反手偷后场 接杀挡网 网前推球 网前扑球 接杀反抽".split())


def encode(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, allow_nan=False)


def clock_fit(path):
    anchors = {}
    for line in path.read_text().splitlines():
        p = json.loads(line)
        host = (p["m3"] + p["m0"]) / 2
        phone = (p["p2"] + p["p1"]) / 2
        rtt = p["m3"] - p["m0"] - (p["p2"] - p["p1"])
        key = int(host / 10)
        if 0 <= rtt < .25 and (key not in anchors or rtt < anchors[key][0]):
            anchors[key] = (rtt, phone, host)
    if not anchors:
        raise ValueError("no clock anchors")
    _, x, y = np.array(sorted(anchors.values(), key=lambda a: a[1])).T
    if x[-1] - x[0] <= 10:
        return 1, y[0] - x[0]
    slope = np.dot(x-x.mean(), y-y.mean()) / np.sum((x-x.mean())**2)
    if not .998 <= slope <= 1.002:
        raise ValueError("clock drift")
    return slope, y.mean() - slope*x.mean()


def extract(times, signals, start, end):
    if not 0 <= start <= end < len(times):
        raise ValueError("invalid boundaries")
    rates = np.linalg.norm(signals[start:end+1, :3], axis=1)
    peak = start + int(np.argmax(rates))
    targets = times[peak] + np.arange(-15, 1) * .01
    first = int(np.searchsorted(times, targets[0], side="right") - 1)
    if first < 0 or np.any(np.diff(times[first:peak+1]) > .04):
        raise ValueError("missing peak history")
    curve = np.stack([np.interp(targets, times[first:peak+1], col[first:peak+1])
                      for col in signals.T], axis=1)
    # Equal weight for waveform shape of rotation and acceleration.
    for group in (curve[:, :3], curve[:, 3:]):
        group /= max(float(np.linalg.norm(group)), 1e-9)
    return first, peak, curve.flatten().round(8).tolist()


def collect(folder, info, allow_weak, rejects):
    if info["state"] != "complete":
        raise ValueError("incomplete session")
    with (folder / "samples.csv").open() as f:
        samples = np.array([[float(r[k]) for k in ["seq", "t_phone", *CHANNELS]]
                            for r in csv.DictReader(f)])
    if samples.ndim != 2 or not np.isfinite(samples).all():
        raise ValueError("invalid IMU")
    if not np.array_equal(samples[:, 0], np.arange(len(samples))) or np.any(np.diff(samples[:, 1]) <= 0):
        raise ValueError("invalid sequence or timestamp")
    times = samples[:, 1]
    with (folder / "trials_index.csv").open() as f:
        labels = list(csv.DictReader(f))
    if labels:
        windows = []
        for r in labels:
            if r["quality"] == "unaligned" or r["session_id"].lower() != info["id"].lower():
                rejects.append([info["id"], r["trial_id"], "unaligned or wrong session"])
                continue
            windows.append((r["actual_label"], int(r["seq_first"]), int(r["seq_last"]), r["trial_id"], "reviewed"))
    elif allow_weak:
        w = json.loads((folder / "action_window.json").read_text())
        if w["session_id"].lower() != info["id"].lower() or w["prompt"] != info["prompt"]:
            raise ValueError("inconsistent action window")
        slope, offset = clock_fit(folder / "clocks.jsonl")
        host = times * slope + offset
        start = int(np.searchsorted(host, w["mac_begin"]))
        end = int(np.searchsorted(host, w["mac_end"], side="right")) - 1
        windows = [(info["prompt"], start, end, "auto", "prompt")]
    else:
        raise ValueError("awaiting review")
    for label, start, end, trial, source in windows:
        try:
            if label not in LABELS:
                raise ValueError("unknown label")
            first, peak, feature = extract(times, samples[:, 2:], start, end)
        except ValueError as e:
            rejects.append([info["id"], trial, str(e)])
            continue
        window = samples[start:end+1]
        other = window[np.abs(window[:, 1] - times[peak]) >= .25]
        peak_rate = float(np.linalg.norm(samples[peak, 2:5]))
        other_rate = float(np.linalg.norm(other[:, 2:5], axis=1).max()) if len(other) else 0
        yield dict(start=start, end=end, speed_peak_rad_s=peak_rate,
                   competing_ratio=other_rate / max(peak_rate, 1e-9),
                   session=info["id"], participant=info["participant"], hand=info["hand"],
                   speed=info.get("speed"), label=label, source=source, trial=trial,
                   first=first, peak=peak, peak_phone_s=times[peak], curve=feature)


def fit(rows):
    groups = defaultdict(list)
    for r in rows:
        groups[r["label"]].append(r["curve"])
    prototypes = {}
    for label, curves in groups.items():
        mean = np.mean(curves, axis=0)
        prototypes[label] = (mean / max(np.linalg.norm(mean), 1e-9)).round(8).tolist()
    return prototypes


def split(data, holdout):
    if holdout:
        people = {r["participant"] for r in data}
        if not set(holdout) <= people:
            raise ValueError("unknown holdout participant")
        return {r["session"] for r in data if r["participant"] in holdout}
    if len({r["participant"] for r in data}) > 1:
        raise ValueError("multiple players: specify --holdout participant IDs")
    groups = defaultdict(set)
    for r in data:
        groups[r["label"]].add(r["session"])
    return {s for sessions in groups.values() if len(sessions) >= 2
            for s in sorted(sessions)[:max(1, len(sessions)//5)]}


def manifests(root):
    for path, dirs, names in os.walk(root):
        dirs.sort()
        if "manifest.json" in names:
            yield Path(path) / "manifest.json"
            dirs.clear()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("root", type=Path)
    p.add_argument("output", type=Path, help="new version directory")
    p.add_argument("--allow-prompt", action="store_true", help="bootstrap unreviewed single-stroke sessions")
    p.add_argument("--holdout", nargs="+", help="independent participant IDs")
    args = p.parse_args()
    if args.output.exists():
        p.error("choose a new output directory")
    data, rejects, seen = [], [], set()
    # Capture roots and exported training packages both contain per-session manifests.
    for manifest in manifests(args.root):
        try:
            info = json.loads(manifest.read_text())
            if info["id"] in seen:
                raise ValueError("duplicate session; choose a root with one copy per session")
            seen.add(info["id"])
            data.extend(collect(manifest.parent, info, args.allow_prompt, rejects))
        except (OSError, KeyError, ValueError) as e:
            if "duplicate session" in str(e):
                p.error(str(e))
            rejects.append([str(manifest.parent.relative_to(args.root)), "", str(e)])
    held = split(data, args.holdout)
    train = [r for r in data if r["session"] not in held]
    test = [r for r in data if r["session"] in held]
    if not train or not test or {r["label"] for r in test} - {r["label"] for r in train}:
        p.error("need independent train/test sessions and training coverage of test labels")
    model = fit(train)
    confusion = defaultdict(Counter)
    predictions = {}
    for r in test:
        pred = max(model, key=lambda label: np.dot(r["curve"], model[label]))
        confusion[r["label"]][pred] += 1
        predictions[r["session"], r["trial"]] = pred
    for r in data:
        r["split"] = "test" if r["session"] in held else "train"
    payload = "\n".join(encode(r) for r in data) + "\n"
    version = hashlib.sha256(payload.encode()).hexdigest()[:16]
    report = dict(version=version, train=len(train), test=len(test), sessions=len(seen),
                  correct=sum(counts[label] for label, counts in confusion.items()),
                  source=Counter(r["source"] for r in data), confusion=confusion, rejected=rejects,
                  samples_per_label=Counter(r["label"] for r in data),
                  train_people=sorted({r["participant"] for r in train}),
                  test_people=sorted({r["participant"] for r in test}))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=args.output.parent) as tmp:
        stage = Path(tmp) / "run"
        stage.mkdir()
        with (stage/"review.csv").open("w", newline="") as f:
            keys = ["session", "trial", "label", "source", "participant", "speed", "split",
                    "start", "end", "first", "peak", "peak_phone_s", "speed_peak_rad_s",
                    "competing_ratio", "held_prediction"]
            writer = csv.DictWriter(f, keys, extrasaction="ignore")
            writer.writeheader()
            for row in sorted(data, key=lambda r: -r["competing_ratio"]):
                writer.writerow(dict(row, held_prediction=predictions.get((row["session"], row["trial"]), "")))
        (stage/"curves.jsonl").write_text(payload)
        (stage/"report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
        (stage/"SwingCurves.json").write_text(encode(dict(schema=1, version=version, prototypes=model)))
        stage.rename(args.output)
    print(encode(report))


if __name__ == "__main__":
    main()
