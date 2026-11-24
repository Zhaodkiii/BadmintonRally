"""Train an optional nearest-centroid model from manually accepted candidate files."""
import argparse
import csv
import json
import math
import statistics
from collections import defaultdict
from pathlib import Path

FEATURES = ["pitch_change", "yaw_magnitude", "peak_rate", "peak_accel", "duration"]
LABELS = {"上挑", "下挥", "平抽", "背景"}

def fit(rows):
    mean = [statistics.mean(col) for col in zip(*(v for _, _, v in rows))]
    scale = [max(statistics.pstdev(col), 1e-6) for col in zip(*(v for _, _, v in rows))]
    groups = defaultdict(list)
    for _, label, values in rows:
        groups[label].append([(v-m)/s for v,m,s in zip(values,mean,scale)])
    centers = {label: [statistics.mean(col) for col in zip(*points)] for label,points in groups.items()}
    radius = {label: max(0.1, 1.25*max(math.dist(p, centers[label])**2 for p in points))
              for label,points in groups.items()}
    return dict(columns=FEATURES, mean=mean, scale=scale, centers=centers, radius=radius)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folder", type=Path)
    parser.add_argument("--holdout", required=True, nargs="+", help="Independent participant IDs")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    rows = []
    for path in args.folder.rglob("*.accepted.csv"):
        with path.open() as file:
            for row in csv.DictReader(file):
                if row["label"] in LABELS:
                    rows.append((row["participant"], row["label"], [float(row[f]) for f in FEATURES]))
    train = [row for row in rows if row[0] not in args.holdout]
    test = [row for row in rows if row[0] in args.holdout]
    if any(set(r[1] for r in split) != LABELS for split in (train, test)):
        parser.error("训练组和留出组均需包含上挑、下挥、平抽和触发候选的背景反例")
    model = fit(train)
    confusion = defaultdict(lambda: defaultdict(int))
    for _,label,v in test:
        z = [(x-m)/s for x,m,s in zip(v,model["mean"],model["scale"])]
        d, pred = min((math.dist(z,c)**2, k) for k,c in model["centers"].items())
        confusion[label][pred if d <= model["radius"][pred] else "拒识"] += 1
    print(json.dumps(confusion,ensure_ascii=False,indent=2))
    with args.output.open("x") as out:
        json.dump(model,out,ensure_ascii=False,indent=2)

if __name__ == "__main__":
    main()
