"""Add right-handed forehand high-serve references from explicitly selected reviewed cuts."""
import argparse
import csv
import json
from pathlib import Path

import numpy as np


def reference(path):
    with path.open(encoding="utf-8-sig") as file:
        rows = list(csv.DictReader(file))
    t = np.array([float(r['相对标记秒']) for r in rows])
    v = np.array([[float(r[k]) for k in 'rx ry rz ax_g ay_g az_g gx gy gz'.split()] for r in rows])
    local = np.flatnonzero(abs(t) <= .30)
    peak = local[np.argmax(np.linalg.norm(v[local, :3], axis=1))]
    grid = t[peak] + np.arange(-15, 1) * .01
    begin = np.searchsorted(t, grid[0]) - 1
    if begin < 0 or max(np.diff(t[begin:peak+1])) > .04:
        raise ValueError(f"Incomplete curve in {path}")
    curve = np.stack([np.interp(grid, t, c) for c in v[:, :6].T], axis=1)
    for block in (curve[:, :3], curve[:, 3:]):
        block /= max(np.linalg.norm(block), 1e-9)
    g = v[peak, 6:]
    return (np.r_[curve.flatten(), g / np.linalg.norm(g)] / np.sqrt(3)).round(8).tolist()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('base', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('cuts', type=Path, nargs='+')
    args = parser.parse_args()
    bank = json.loads(args.base.read_text())
    bank['highServeReferences'] = [reference(p) for p in args.cuts]
    args.output.write_text(json.dumps(bank, ensure_ascii=False, sort_keys=True))
