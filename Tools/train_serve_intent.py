"""Fit a small serve-intent reference bank from reviewed peaks and specialist training sessions."""
import argparse
import csv
import json
from pathlib import Path

import numpy as np


def features(samples, peak):
    window = samples[(samples[:, 0] > peak - .16) & (samples[:, 0] <= peak + .000001)]
    result = []
    for i in range(4):
        age = peak - window[:, 0]
        part = window[(age < (4-i)*.04) & (age >= (3-i)*.04-.000001)]
        if len(part) < 2:
            raise ValueError(f"Incomplete IMU window at {peak}")
        for axes in (part[:, 1:4], part[:, 4:7]):
            result.append(float(np.log1p(np.linalg.norm(axes, axis=1).mean())))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('captures', 'reviews', 'examples', 'output'):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    data = {'positive': [], 'negative': []}
    cache = {}

    def add(session, peak, label, match):
        if session not in cache:
            file = (args.captures/'比赛实时诊断'/session/'分析/motion.csv' if match
                    else args.captures/session/'samples.csv')
            with file.open(encoding='utf-8-sig') as stream:
                cache[session] = np.array([[float(row[k]) for k in
                    ('t_phone','rx','ry','rz','ax_g','ay_g','az_g')] for row in csv.DictReader(stream)])
        data[label].append(features(cache[session], peak))

    for file in sorted(args.reviews.glob('*/发球意图复核.csv')):
        with file.open(encoding='utf-8-sig') as stream:
            for row in csv.DictReader(stream):
                if row['intent'] in data:
                    add(row['session'], float(row['peak']), row['intent'], True)
    serves = {'反手短发','正手短发球','正手高远发球','反手偷后场'}
    for row in json.loads(args.examples.read_text()):
        if row['split'] == 'train' and row['source'] in {'人工复核','录像抽帧复核'} and row['label'] in serves:
            add(row['session'], row['peak'], 'positive', False)
    if not all(data.values()):
        raise ValueError('需要已复核的主挥和误触样本')
    reviews = sorted(args.reviews.glob("*/发球阶段标注.csv"))
    if reviews:
        from fit_serve_direction import fit
        data = fit(data, args.captures / "比赛实时诊断", reviews)
    args.output.write_text(json.dumps(data, allow_nan=False))
    print({label: len(items) for label, items in data.items() if label != 'direction'})


if __name__ == '__main__':
    main()
