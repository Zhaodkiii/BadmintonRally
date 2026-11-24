"""Fit the on-device serve readout from reviewed trials and named, button-marked serves."""
import argparse
import json
from collections import Counter
from pathlib import Path

import numpy as np
from sklearn.linear_model import LogisticRegression

LABELS = ["正手高远发球", "正手短发球", "反手短发球", "反手偷后场"]


def features(frames, t):
    pre = frames[(frames[:, 0] > t - .24) & (frames[:, 0] <= t)]
    if len(pre) < 6 or t - pre[-1, 0] > .06 or np.diff(pre[:, 0]).max() > .05:
        return None
    output = []
    for lo, hi in [(.24, .16), (.16, .08), (.08, 0)]:
        data = pre[(pre[:, 0] > t - lo) & (pre[:, 0] <= t - hi), 1:10]
        if len(data) < 2:
            return None
        mean = data.mean(axis=0)
        output.extend(np.r_[np.arcsinh(mean[:3] / 4), np.arcsinh(mean[3:6]), mean[6:9]])
    return output


def collect(root, reviewed):
    for row in json.loads(reviewed.read_text()):
        label = row["label"].replace("反手短发", "反手短发球") if row["label"] == "反手短发" else row["label"]
        if label not in LABELS or row["source"] not in {"人工复核", "录像抽帧复核"}:
            continue
        folder = root / row["session"]
        if json.loads((folder / "manifest.json").read_text()).get("hand") != "右手":
            continue
        frames = np.loadtxt(folder / "samples.csv", skiprows=1, delimiter=",")[:, 1:11]
        yield folder.name, label, features(frames, row["peak"])
    for folder in sorted((root / "比赛实时诊断").glob("*/batches")):
        frames, marks = [], []
        for path in sorted(folder.glob("*.json")):
            batch = json.loads(path.read_text())
            state = batch["state"]
            mode = state["mode"].split("/")
            if state.get("input") != "volumeButton":
                break
            frames.extend([f["t"], *f["v"][:9]] for f in batch["frames"])
            if state["leftHand"] or len(mode) < 6 or mode[1] != "我方发球" or mode[5] not in LABELS:
                continue
            for event in batch["events"]:
                if event["kind"] == "judgment" and event.get("accepted"):
                    marks.append((event["peakTime"], mode[5]))
        if marks:
            data = np.array(sorted(frames))
            for t, label in marks:
                yield folder.parent.name, label, features(data, t)


def fit(x, y, groups):
    # Equal class weight, then equal weight per recording within a class.
    counts = Counter(zip(y, groups))
    sessions = Counter(label for label, group in counts)
    weight = np.array([1 / (counts[label, group] * sessions[label]) for label, group in zip(y, groups)])
    return LogisticRegression(C=2, max_iter=1000).fit(x, y, sample_weight=weight / weight.mean())


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    for name in ("root", "reviewed", "output"):
        cli.add_argument(name, type=Path)
    args = cli.parse_args()
    rows = [(g, y, x) for g, y, x in collect(args.root, args.reviewed) if x is not None]
    groups, y, x = map(np.array, zip(*rows))
    if set(y) != set(LABELS):
        raise ValueError("需要四类有效发球样本")
    results = Counter()
    for g in sorted(set(groups)):
        train = groups != g
        if set(y[train]) != set(LABELS):
            results.update((label, "无独立训练场") for label in y[~train])
            continue
        model = fit(x[train], y[train], groups[train])
        for truth, prob in zip(y[~train], model.predict_proba(x[~train])):
            ranks = np.argsort(prob)
            confident = prob[ranks[-1]] >= .55 and prob[ranks[-1]] - prob[ranks[-2]] >= .15
            prediction = model.classes_[ranks[-1]] if confident else "待定"
            results[truth, prediction] += 1
    model = fit(x, y, groups)
    args.output.write_text(json.dumps(dict(labels=list(model.classes_), weights=model.coef_.tolist(),
        bias=model.intercept_.tolist(), minimum=.55, margin=.15), ensure_ascii=False))
    print("训练", Counter(y), "场次", len(set(groups)), "整场留出", results)


if __name__ == "__main__":
    main()
