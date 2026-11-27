"""Cross-session rear-court return experiment using raw pre-press IMU only."""
import csv
import json
from collections import Counter
from pathlib import Path

import numpy as np
from train_button_serves import features, fit
from prepare_raw_swing import ROOT, INPUT, write, window, variant

OUT = ROOT / 'data/正式对局验收/P039/回球训练'
SESSIONS = ['10FCBB8A-F213-41AB-BD1E-C8E829EC4108', '9C281EFA-1F8F-4FD5-8B01-C8948DEC79D3',
            'F29AC091-76F5-456B-9938-90A76FE294AF']
LABELS = {'扣杀','吊球','高远球'}
CHANNELS = ['rx','ry','rz','ax_g','ay_g','az_g','gx','gy','gz']


def physical(session):
    folder = INPUT/session
    marks, contacts, frames = {}, {}, {}
    for path in sorted((folder/'batches').glob('*.json')):
        batch = json.loads(path.read_bytes())
        state = batch['state']
        if state['leftHand'] or state.get('input') != 'volumeButton':
            continue
        for row in batch['frames']:
            frames[row['t']] = row['v'][:9]
        for e in batch['events']:
            if e['kind']=='manualContact':
                marks[e['gameTime']]=e['time']
            c=e.get('contact',{})
            if c.get('intendedReply') in LABELS and c['area']=='后场' and not c['beforeNet']:
                contacts[e['gameTime']]=c
    mat=np.array([[t,*frames[t]] for t in sorted(frames)])
    for g,c in sorted(contacts.items()):
        if g not in marks:
            continue
        r=window(mat,marks[g],session,c['intendedReply'],'physical-volume-key')
        if r:
            yield dict(r,trial=c['trial'],originalReply=c.get('observedReply'))


def support():
    review = ROOT/'data/动作采集分析/本地训练台/20261123-072858-687220/examples.json'
    for r in json.loads(review.read_text()):
        if r['label']!='正手扣杀' or r['source'] not in ['录像抽帧复核','人工复核']:
            continue
        folder=INPUT.parent/r['session']
        if json.loads((folder/'manifest.json').read_text())['hand']!='右手':
            continue
        mat=np.loadtxt(folder/'samples.csv',delimiter=',',skiprows=1)[:,1:11]
        item=window(mat,r['peak'],r['session'],'扣杀','human-reviewed peak proxy')
        if item:
            yield item
    # Auxiliary weak supervision, limited to complete right-handed guided recordings with a
    # distinct peak inside the cued forward swing. Never use these proxies for the key metric.
    for path in sorted((ROOT/'data/早期动作采集').glob('*-complete.csv')):
        with path.open() as f:
            rows=list(csv.DictReader(f))
        label={'正手扣杀':'扣杀','头顶高远':'高远球','吊球':'吊球'}.get(rows[0]['prompt'])
        if not label or rows[0]['hand']!='R':
            continue
        mat=np.array([[float(r[k]) for k in ['t_s',*CHANNELS]] for r in rows])
        mask=np.array([r['cue_phase']=='挥出' for r in rows])
        mag=np.linalg.norm(mat[:,1:4],axis=1)
        if not mask.any():
            continue
        best=np.flatnonzero(mask)[np.argmax(mag[mask])]
        if mag[best]<4 or mag[best]<.75*mag.max():
            continue
        c=window(mat,mat[best,0],rows[0]['session'],label,'guided phase peak, weak label')
        if c:
            yield c


def x(row):
    return features(np.asarray(row['frames']),row['press'])


def train(rows, augmented):
    bank=list(rows)
    if augmented:
        for row in rows:
            bank.extend(variant(row,a,s) for a in (-15,0,15) for s in (.85,1.,1.15) if (a,s)!=(0,1))
    bank=[r for r in bank if x(r) is not None]
    m=fit(np.array([x(r) for r in bank]),[r['label'] for r in bank],[r['session'] for r in bank])
    assert set(m.classes_)==LABELS
    return m


def main():
    rows=[r for s in SESSIONS for r in physical(s)]
    aux=list(support())
    rows=[r for r in rows if x(r) is not None]
    aux=[r for r in aux if x(r) is not None]
    out=[]
    for session in SESSIONS:
        held=[r for r in rows if r['session']==session]
        train_rows=[r for r in rows if r['session']!=session]+aux
        pred={}
        for model,aug in [('raw',False),('augmented',True)]:
            m=train(train_rows,aug)
            probs=m.predict_proba([x(r) for r in held])
            pred[model]=[(m.classes_[p.argmax()],round(float(p.max()),4)) for p in probs]
        for j,r in enumerate(held):
            out.append({**{k:r[k] for k in ['id','trial','session','label','originalReply']},
                        **{m:p[j] for m,p in pred.items()}})
    final=train(rows+aux,True)
    write(OUT/'RawReturnCandidate.json',dict(classes=final.classes_.tolist(),weights=final.coef_.tolist(),
          bias=final.intercept_.tolist(),minimum=.75,scope='right rear overhead; shadow evaluation only'))
    write(OUT/'折外逐按键预测.json',out)
    totals={}
    for label in sorted(LABELS):
        sub=[r for r in out if r['label']==label]
        totals[label]=dict(n=len(sub),recorded=sum(r['originalReply']==label for r in sub),
                           raw=sum(r['raw'][0]==label for r in sub),
                           augmented=sum(r['augmented'][0]==label for r in sub),
                           confident=sum(r['augmented'][1]>=.75 for r in sub),
                           confidentCorrect=sum(r['augmented'][1]>=.75 and r['augmented'][0]==label for r in sub))
    write(OUT/'训练与边界.json',dict(totals=totals,hardwareSessions=SESSIONS,
          support=[{k:v for k,v in r.items() if k!='frames'} for r in aux],
          independentHardwareCount=len(rows),sourceCounts=dict(Counter(r['anchor'] for r in rows+aux))))
    print(totals)



def latest_shadow():
    session='B68865BF-1354-4B99-BA10-6A5A92959CAC'
    d=INPUT/session/'分析'
    def read(name):
        with (d/name).open(encoding='utf-8-sig') as f:
            return list(csv.DictReader(f))
    states=read('events.csv')
    keys={e['gameTime']:float(e['time']) for e in states if e['kind']=='manualContact'}
    sensor=np.array([[float(r[k]) for k in ['t_phone',*CHANNELS]] for r in read('motion.csv')])
    m=json.loads((OUT/'RawReturnCandidate.json').read_text())
    rows=[]
    for event in states:
        if event['kind']!='judgment' or event['text'] not in ['tooHigh','outOfReach','late']:
            continue
        t=keys[event['gameTime']]
        f=features(sensor,t)
        row=dict(press=t,gameTime=float(event['gameTime']),originalDirection=event['candidateGame'],
                 judgment=event['text'],truth=None)
        if f is not None:
            l=np.array(m['weights'])@f+m['bias']
            p=np.exp(l-max(l))
            p/=p.sum()
            row.update(shadow=m['classes'][int(p.argmax())],confidence=float(p.max()),
                       probabilities=dict(zip(m['classes'],p.tolist())))
        rows.append(row)
    assert len(rows)==22
    write(OUT/'B688-22次接球影子.json',rows)
    print('B688',Counter(r.get('shadow','no-samples') for r in rows))


def invariants(c):
    # Rigid-rotation invariant features distinguish axial loading, instantaneous braking,
    # and wrist speed without using the absolute direction a player holds the device.
    a=np.array(c['frames'])
    t=a[:,0]-c['press']
    values=[]
    for lo,hi in [(-.24,-.16),(-.16,-.08),(-.08,0)]:
        v=a[(t>lo)&(t<=hi)]
        w,acc,g=v[:,1:4],v[:,4:7],v[:,7:10]
        gravity=g/np.maximum(np.linalg.norm(g,axis=1,keepdims=True),.1)
        values.extend([np.log1p(np.linalg.norm(w,axis=1)).mean(),np.log1p(np.linalg.norm(acc,axis=1)).mean(),
                       np.arcsinh(np.sum(w*gravity,axis=1)/4).mean(),
                       np.arcsinh(np.sum(acc*gravity,axis=1)).mean()])
    return values


def compare_invariants():
    rows=[r for session in SESSIONS for r in physical(session) if x(r) is not None]
    aux=[r for r in support() if x(r) is not None]
    out=[]
    for session in SESSIONS:
        held=[r for r in rows if r['session']==session]
        refs=[r for r in rows if r['session']!=session]+aux
        groups=[r['session'] for r in refs]
        m=fit(np.array([invariants(r) for r in refs]),[r['label'] for r in refs],groups)
        p=m.predict_proba(np.array([invariants(r) for r in held]))
        for r,prob in zip(held,p):
            out.append(dict(id=r['id'],label=r['label'],prediction=m.classes_[prob.argmax()],
                            confidence=float(prob.max())))
    write(OUT/'重力与能量特征折外对照.json',out)
    print('invariants',Counter(r['label'] for r in out if r['prediction']==r['label']))


if __name__=='__main__':
    OUT.mkdir(parents=True,exist_ok=True)
    main()
    latest_shadow()
    compare_invariants()
