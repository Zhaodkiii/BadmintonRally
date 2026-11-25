"""Fit pre-button rear-corner gestures and compare short and extended histories."""
import argparse
import json
from collections import Counter
from pathlib import Path

import numpy as np
from sklearn.linear_model import LogisticRegression
from sklearn.preprocessing import StandardScaler

CORNER = {'反手高远', '反手吊球', '头顶正手处理'}
WINDOWS = [(-0.65, -0.32), (-0.32, -0.15), (-0.15, -0.06), (-0.06, 0)]


def session_rows(folder):
    frames, contacts = {}, []
    for path in sorted((folder / 'batches').glob('*.json')):
        batch = json.loads(path.read_bytes())
        if batch['state']['leftHand']:
            continue
        frames.update((f['t'], f['v'][:6]) for f in batch['frames'])
        contacts.extend((e['time'], e['contact']) for e in batch['events'] if e.get('contact'))
    if not frames:
        return []
    times = np.array(sorted(frames))
    signal = np.array([frames[t] for t in times])
    rows = []
    for t, c in sorted(contacts):
        if c['area'] != '后场' or c['strength'] < 0.09:
            continue
        segments = [signal[(times > t+a) & (times <= t+b)] for a,b in WINDOWS]
        period = times[(times > t-0.65) & (times <= t)]
        if min(map(len,segments)) < 3 or max(np.diff(period)) > 0.05 or t-period[-1] >= 0.06:
            continue
        x = np.concatenate([s.mean(axis=0) for s in segments])
        rows.append((c['intendedReply'], x, c['trial']))
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('sessions', type=Path, nargs='+')
    args = parser.parse_args()
    train, test = [], []
    for folder in args.sessions:
        rows = session_rows(folder)
        k = 3*len(rows)//4
        train.extend(rows[:k])
        test.extend(rows[k:])
    for start in [12,0]:
        def arrays(rows):
            return np.array([r[1][start:] for r in rows]), [r[0] if r[0] in CORNER else '其他' for r in rows]
        x,y = arrays(train)
        scaler = StandardScaler().fit(x)
        model = LogisticRegression(C=0.2,class_weight='balanced',max_iter=1000).fit(scaler.transform(x),y)
        tx,ty = arrays(test)
        pred = model.predict_proba(scaler.transform(tx))
        print('channels',x.shape[1], 'train',Counter(y), 'holdout',Counter((a,model.classes_[p.argmax()] if max(p)>=0.60 else '不确定') for a,p in zip(ty,pred)))
    weights = model.coef_/scaler.scale_
    args.output.write_text(json.dumps(dict(classes=model.classes_.tolist(),weights=weights.tolist(),
        bias=(model.intercept_-weights@scaler.mean_).tolist(),sessions=[p.name for p in args.sessions]),ensure_ascii=False,indent=2)+'\n')


if __name__ == '__main__':
    main()
