"""Build a conservative right-hand trajectory bank from the training split only."""
import argparse
import csv
import json
from collections import Counter
from pathlib import Path

import numpy as np
from train_curves import CHANNELS


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("examples", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    bank, speeds, sessions = {}, [], []
    for row in json.loads(args.examples.read_text()):
        if row["split"] != "train" or row["source"] not in {"人工复核", "录像抽帧复核"}:
            continue
        folder = args.root / row["session"]
        manifest = json.loads((folder / "manifest.json").read_text())
        if manifest.get("hand") != "右手":
            continue
        with (folder / "samples.csv").open() as stream:
            samples = np.array([[float(s[k]) for k in ["t_phone", *CHANNELS, "gx", "gy", "gz"]] for s in csv.DictReader(stream)])
        ts = samples[:, 0]
        target = row["peak"] + np.arange(-15, 1) * .01
        start, end = np.searchsorted(ts, target[[0, -1]])
        if start == 0 or end >= len(ts) or np.max(np.diff(ts[start-1:end+1])) > .04:
            continue
        curve = np.array([np.interp(target, ts, col) for col in samples[:, 1:7].T]).T
        speeds.append(np.linalg.norm(curve[-1, :3]))
        for part in (curve[:, :3], curve[:, 3:]):
            part /= max(np.linalg.norm(part), 1e-9)
        gravity = np.array([np.interp(row["peak"], ts, col) for col in samples[:, 7:10].T])
        vector = np.r_[curve.flatten(), gravity / max(np.linalg.norm(gravity), 1e-9)] / np.sqrt(3)
        bank.setdefault(row["label"], []).append(vector.round(8).tolist())
        sessions.append((row["session"], row["label"], vector))
    if len({s for s, _, _ in sessions}) != len(sessions):
        raise ValueError("Expected a different capture session for each exemplar")
    # Require two independent supporting swings and evaluate each training session
    # with its own exemplar removed. Unvalidated classes still act as competitors.
    choices = []
    for threshold in (.88, .90, .92, .94):
        for margin in (.03, .05, .08):
            good, bad = Counter(), Counter()
            for session, truth, v in sessions:
                ranks = sorted(((v @ other, label) for s, label, other in sessions if s != session), reverse=True)
                top, label = ranks[0]
                same = [s for s, k in ranks if k == label]
                other = max(s for s, k in ranks if k != label)
                if len(same) >= 2 and same[1] >= threshold and top-other >= margin:
                    (good if label == truth else bad)[label] += 1
            enabled = sorted(k for k in good if good[k] >= 2 and not bad[k])
            choices.append((sum(good[k] for k in enabled), threshold, margin, enabled))
    support, threshold, margin, enabled = max(choices)
    if not support:
        raise ValueError("No class passes cross-session validation")
    data = dict(schema=1, templates=bank, enabled=enabled, threshold=threshold, margin=margin,
                fullPower=float(np.percentile(speeds, 90)))
    args.output.write_text(json.dumps(data, ensure_ascii=False, sort_keys=True))
    print(len(sessions), "training sessions;", support, "leave-one-session-out confirmations;", enabled, threshold, margin)


if __name__ == "__main__":
    main()
