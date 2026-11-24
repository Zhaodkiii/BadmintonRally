"""Offline 14-class template baseline, using up to 80 ms of motion after the candidate peak."""
import argparse
import csv
import json
from pathlib import Path

import numpy as np
from train_curves import CHANNELS


def train(root, run):
    rows = list(csv.DictReader((run/'review.csv').open()))
    features = []
    for r in rows:
        samples = list(csv.DictReader((root/r['session']/'samples.csv').open()))
        time = np.array([float(s['t_phone']) for s in samples])
        peak = float(r['peak_phone_s'])
        target = peak + np.arange(-24, 9)*.01
        if target[0] < time[0] or target[-1] > time[-1]:
            raise ValueError(f"Incomplete window {r['session']}")
        axes = np.array([np.interp(target,time,[float(s[k]) for s in samples]) for k in CHANNELS]).T
        blocks = np.array_split(axes, 6)
        features.append(np.concatenate([b.mean(axis=0) for b in blocks] +
            [np.array([np.linalg.norm(axes[:,:3],axis=1).max(),np.linalg.norm(axes[:,3:],axis=1).max()])]))
    x = np.array(features)
    train = np.array([r['split']=='train' for r in rows])
    labels = np.array([r['label'] for r in rows])
    classes = np.unique(labels[train])
    mean, scale = x[train].mean(axis=0), np.maximum(x[train].std(axis=0), .01)
    z = (x-mean)/scale
    centers = np.array([z[train & (labels==label)].mean(axis=0) for label in classes])
    np.savez(run/'phase_model.npz', classes=classes, mean=mean, scale=scale, centers=centers)
    with (run/'phase_predictions.csv').open('w', newline='') as dest:
        w=csv.writer(dest);w.writerow(['session','label','prediction'])
        for row, sample in zip(np.array(rows)[~train],z[~train]):
            pred=classes[np.argmin(np.linalg.norm(centers-sample,axis=1))]
            w.writerow([row['session'],row['label'],pred])


if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('root',type=Path); p.add_argument('run',type=Path)
    args=p.parse_args(); train(args.root,args.run)
