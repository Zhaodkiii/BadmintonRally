"""Fit signed IMU reference curves from reviewed right-handed serve-phase intervals."""
import argparse
import csv
import json
from pathlib import Path

import numpy as np


def fit(base, matches, reviews):
    groups = {'positive': [], 'negative': []}
    speeds, accelerations = [], []
    for review in reviews:
        with review.open(encoding='utf-8-sig') as stream:
            rows = list(csv.DictReader(stream))
        for session in sorted({r['session'] for r in rows}):
            folder = matches / session / '分析'
            with (folder / 'states.csv').open(encoding='utf-8-sig') as stream:
                if next(csv.DictReader(stream))['leftHand'] != 'False':
                    raise ValueError(f'Expected right-handed capture: {session}')
            with (folder / 'motion.csv').open(encoding='utf-8-sig') as stream:
                samples = np.array([[float(r[k]) for k in 't_phone rx ry rz ax_g ay_g az_g'.split()]
                                    for r in csv.DictReader(stream)])
            for row in rows:
                if row['session'] != session or row['split'] != 'train':
                    continue
                if row['intent'] == 'positive' and row['action'] != '正手高远发球':
                    raise ValueError('Positive reference must be a reviewed forehand high serve')
                grid = float(row['peak']) + np.arange(-15, 1) * .01
                times = samples[:, 0]
                lo = np.searchsorted(times, grid[0]) - 1
                hi = np.searchsorted(times, grid[-1])
                if lo < 0 or hi >= len(times) or max(np.diff(times[lo:hi+1])) > .04:
                    raise ValueError(f'Missing IMU frames at {grid[-1]}')
                curve = np.stack([np.interp(grid, times, v) for v in samples[:, 1:].T], axis=1)
                if row['intent'] == 'positive':
                    speeds.append(float(np.linalg.norm(curve[-1, :3])))
                    accelerations.append(float(np.linalg.norm(curve[-1, 3:])))
                for block in (curve[:, :3], curve[:, 3:]):
                    block /= max(np.linalg.norm(block), 1e-9)
                groups[row['intent']].append(curve.flatten().round(8).tolist())
    if min(map(len, groups.values())) < 2:
        raise ValueError('Each intent needs at least two reviewed curves')
    return dict(base, direction=dict(groups, minPeak=0.65 * min(speeds),
                                     minAcceleration=0.50 * min(accelerations)))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ('base', 'matches', 'output'):
        parser.add_argument(key, type=Path)
    parser.add_argument('reviews', nargs='+', type=Path)
    args = parser.parse_args()
    model = fit(json.loads(args.base.read_text()), args.matches, args.reviews)
    args.output.write_text(json.dumps(model, allow_nan=False))
