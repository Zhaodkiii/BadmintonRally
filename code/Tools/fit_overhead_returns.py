"""Fit the rear-court clear/drop disambiguator and smash classifier."""
import argparse
import json
import re
from pathlib import Path

import numpy as np
from sklearn.linear_model import LogisticRegression
from sklearn.preprocessing import StandardScaler


def contacts(folder):
    rows = []
    loads = {}
    candidates = []
    for file in sorted((folder / 'batches').glob('*.json')):
        batch = json.loads(file.read_bytes())
        for event in batch['events']:
            if event['kind'] == 'impact':
                value = re.search(r'轴向加速度 ([+-]?[0-9.]+) g', event.get('text', ''))
                if value:
                    loads[event['gameTime']] = float(value[1])
            c = event.get('contact')
            if c and not batch['state']['leftHand'] and c['area'] == '后场' and not c['beforeNet']:
                candidates.append((event['gameTime'],c))
    for time,c in sorted(candidates):
        if c['strength'] < 0.09 or c.get('braking') is None or time not in loads:
            continue
        rows.append((c['trial'], c['intendedReply'], [c['power'], c['sweep'], c['vertical'], c['braking'],loads[time]]))
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('sessions', type=Path, nargs='+')
    args = parser.parse_args()
    train, held = [], []
    for folder in args.sessions:
        rows = contacts(folder)
        k = len(rows)*3//4
        train.extend(rows[:k])
        held.extend(rows[k:])
    scaler = StandardScaler().fit([r[2] for r in train])
    model = LogisticRegression(C=0.65, class_weight='balanced').fit(
        scaler.transform([r[2] for r in train]), [r[1] for r in train])
    assert set(model.classes_) == {'扣杀','吊球','高远球'}
    weights = model.coef_ / scaler.scale_
    payload = dict(classes=model.classes_.tolist(), weights=weights.tolist(),
                   bias=(model.intercept_-weights@scaler.mean_).tolist(),
                   sessions=[p.name for p in args.sessions], trainCount=len(train))
    args.output.write_text(json.dumps(payload, ensure_ascii=False, indent=2)+'\n')
    for name in model.classes_:
        subset = [r for r in held if r[1]==name]
        probs = model.predict_proba(scaler.transform([r[2] for r in subset]))
        print(name,len(subset),[(r[0],model.classes_[p.argmax()],round(p.max(),2)) for r,p in zip(subset,probs)])


if __name__ == '__main__':
    main()
