"""Build deterministic raw-sensor replay clips and train the four-way serve readout."""
import argparse
import json
from collections import Counter
from pathlib import Path

import numpy as np
from train_button_serves import LABELS, features, fit

ROOT = Path(__file__).resolve().parents[2]
INPUT = ROOT / 'data/动作采集/比赛实时诊断'
OUT = ROOT / 'data/正式对局验收/P038/挥拍数据'
RES = ROOT / 'code/Clients/iOS/Resources'
SEED = 'F97AD7A0-AC68-427B-A4E7-51A5D2958F82'


def write(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, separators=(',', ':'), allow_nan=False))


def clips(folder):
    frames, marks = {}, []
    for path in sorted((folder / 'batches').glob('*.json')):
        b = json.loads(path.read_text())
        s = b['state']
        mode = s['mode'].split('/')
        if s.get('leftHand') or s.get('input') != 'volumeButton' or mode[0] != '场景采集':
            continue
        for f in b['frames']:
            frames[f['t']] = f['v'][:9]
        if len(mode) < 6:
            continue
        serve = mode[1] == '我方发球'
        label = mode[5] if serve else (mode[7] if len(mode) > 7 else '')
        if label not in (LABELS if serve else ['高远球','扣杀','吊球','推球','扑球','反手高远','平高球']):
            continue
        for e in b['events']:
            if e['kind'] == 'manualContact':
                marks.append((e['time'], label, 'serve' if serve else 'return', path.name, e['text']))
    if not frames:
        return []
    arr = np.array([[t,*frames[t]] for t in sorted(frames)])
    output = []
    for t,label,role,filename,key in marks:
        win = arr[(arr[:,0]>=t-.72)&(arr[:,0]<=t+.07)].copy()
        if len(win)<65 or np.max(np.diff(win[:,0]))>.04 or t-win[0,0]<.65:
            continue
        start = win[0,0]
        win[:,0] -= start
        output.append(dict(id=f'{folder.name}_{t:.6f}',session=folder.name,label=label,role=role,
                           batch=filename,key=key,sourcePress=t,press=t-start,frames=win.tolist()))
    return output


def seed():
    item=clips(INPUT/SEED)[0]
    write(RES/'RawSwingReplay.json', {'clips':[item]})
    write(OUT/'单球原始记录.json',item)
    print(item['id'],item['label'],item['batch'],item['press'],len(item['frames']))



def plot(item, dest):
    from PIL import Image, ImageDraw, ImageFont
    im = Image.new('RGB',(1200,800),'white')
    d = ImageDraw.Draw(im)
    font = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc',22)
    small = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc',16)
    data = np.array(item['frames'])
    d.text((25,12),'Recorded right-hand swing  |  100 Hz nominal  |  physical volume-up press',font=font,fill='#151819')
    d.text((25,51),item['id'],font=small,fill='#334155')
    for i,unit in enumerate(('Angular velocity (rad/s)','User acceleration (g)','Gravity (g)')):
        axis = data[:,1+i*3:4+i*3]
        limit=max(1,int(np.ceil(abs(axis).max())))
        top=120+i*219
        def xy(t,value):
            return (100+1040*t/data[-1,0],top+78-value/limit*72)
        d.text((16,top-30),unit,font=font,fill='#334155')
        for value in [-limit,0,limit]:
            d.line([xy(0,value),xy(data[-1,0],value)],fill='#dee4e8')
            d.text((30,xy(0,value)[1]-9),str(value),fill='#334155',font=small)
        for c,color in enumerate(('#143c91','#a13a28','#167243')):
            d.line([xy(t,v) for t,v in zip(data[:,0],axis[:,c])],fill=color,width=2)
            d.text((760+c*60,top-26),'xyz'[c],fill=color,font=font)
        px=xy(item['press'],0)[0]
        d.line([(px,top),(px,top+155)],fill='#a22790',width=2)
        d.text((px-70,top-26),'key +',fill='#a22790',font=small)
    d.text((370,760),f"Seconds from first sample    0.000 — {data[-1,0]:.3f}    |    press {item['press']:.6f} s",font=font,fill='#334155')
    im.save(dest)


def originals():
    items=[]
    for d in sorted(INPUT.iterdir()):
        files=sorted((d/'batches').glob('*.json'))
        if files and json.loads(files[0].read_text())['state']['mode'].startswith('场景采集'):
            items.extend(clips(d))
    return items


def reviewed():
    import csv
    src = ROOT/'data/动作采集分析'
    review = src/'本地训练台/20261123-072858-687220/examples.json'
    for r in json.loads(review.read_text()):
        label='反手短发球' if r['label']=='反手短发' else r['label']
        if label not in LABELS or r['source'] not in ['人工复核','录像抽帧复核']:
            continue
        d = INPUT.parent/r['session']
        if json.loads((d/'manifest.json').read_text())['hand']!='右手':
            continue
        yield window(np.loadtxt(d/'samples.csv',delimiter=',',skiprows=1)[:,1:11],r['peak'],
                     r['session'],label,'reviewed sensor peak')
    for path in sorted(src.glob('*/发球阶段标注.csv')):
        sid=path.parent.name
        with (INPUT/sid/'分析/motion.csv').open(encoding='utf-8-sig') as data:
            mat = np.array([[float(row[k]) for k in
                             ('t_phone','rx','ry','rz','ax_g','ay_g','az_g','gx','gy','gz')]
                            for row in csv.DictReader(data)])
        with path.open(encoding='utf-8-sig') as data:
            for row in csv.DictReader(data):
                if row['intent']=='positive' and row['action'] in LABELS:
                    yield window(mat,float(row['peak']),sid,row['action'],'reviewed video/phase anchor')


def window(mat, t, session, label, anchor):
    a=mat[(mat[:,0]>=t-.72)&(mat[:,0]<=t+.07)].copy()
    if len(a)<65 or np.diff(a[:,0]).max()>.04: return None
    start=a[0,0]
    a[:,0]-=start
    return dict(id=f'{session}_{t:.6f}',label=label,session=session,role='serve',
                press=t-start,frames=a.tolist(),anchor=anchor)


def variant(item, angle, speed):
    """Rigid tilt about the device y-axis and uniform retiming of a fixed path."""
    a=np.array(item['frames'])
    theta=np.deg2rad(angle)
    rot=np.array([[np.cos(theta),0,np.sin(theta)],[0,1,0],[-np.sin(theta),0,np.cos(theta)]])
    source=a[:,0].copy()
    t=np.arange(0,source[-1]/speed,0.01)
    chans=[]
    for j,factor in enumerate((speed,speed**2,1)):
        v=a[:,1+j*3:4+j*3]@rot.T
        chans.extend(np.interp(t*speed,source,vec)*factor for vec in v.T)
    return {**item,'id':f"{item['id']}_tilt{angle:+d}_tempo{speed:.2f}",
            'parent':item['id'],'angleDegrees':angle,'speed':speed,
            'press':item['press']/speed,'frames':np.column_stack([t,*chans]).tolist()}


def probabilities(model, x):
    weights,bias = np.array(model['weights']),np.array(model['bias'])
    logits=x@weights.T+bias
    ex=np.exp(logits-logits.max(axis=1,keepdims=True))
    p=ex/ex.sum(axis=1,keepdims=True)
    pair=np.sort(p,axis=1)[:,-2:]
    return np.where((pair[:,1]>=model['minimum']) & (pair[:,1]-pair[:,0]>=model['margin']),
                    np.array(model['labels'])[p.argmax(axis=1)],'待定')


def feature(item):
    return features(np.array(item['frames']),item['press'])


def train():
    cache=OUT/'原始按键窗口.json'
    raw=json.loads(cache.read_text()) if cache.is_file() else originals()
    serves=[c for c in raw if c['role']=='serve']+[c for c in reviewed() if c]
    # Hold one complete recording per class, including a separate video-reviewed high serve.
    held={'2AE8C501-AD01-4085-865C-D2E557CA8E6F','5EE1CCCE-A31F-45CE-983C-00163F46CC89',
          '3E4C2B93-3AE3-44DE-B73D-AA0DBB367A34','0E7CB61C-CE6E-4546-BFE8-07F6FD6381F6'}
    train_set=[x for x in serves if x['session'] not in held and feature(x) is not None]
    test_set=[x for x in serves if x['session'] in held and feature(x) is not None]
    assert set(x['label'] for x in test_set)==set(LABELS)
    y=np.array([x['label'] for x in test_set])
    x=np.array([feature(c) for c in test_set])
    def score(m):
        p=probabilities(m,x)
        return {lab:dict(correct=int(((p==y)&(y==lab)).sum()),total=int((y==lab).sum()),
                         abstained=int(((p=='待定')&(y==lab)).sum()))
                for lab in LABELS}
    report=dict(holdoutSessions=sorted(held),holdout=[{k:v for k,v in c.items() if k!='frames'} for c in test_set],
                trainingSources=[{k:v for k,v in c.items() if k!='frames'} for c in train_set],
                evaluation={'shipped_overlap_unknown':score(json.loads((RES/'ButtonServes.json').read_text()))})
    angles=(-15,0,15)
    speeds=(.85,1.,1.15)
    for key in ('real','augmented'):
        rows=list(train_set)
        if key=='augmented':
            for c in train_set:
                rows.extend(variant(c,a,s) for a in angles for s in speeds if (a,s)!=(0,1))
        rows=[c for c in rows if feature(c) is not None]
        m=fit(np.array([feature(c) for c in rows]),[c['label'] for c in rows],[c['session'] for c in rows])
        model=dict(labels=m.classes_.tolist(),weights=m.coef_.tolist(),bias=m.intercept_.tolist(),minimum=.55,margin=.15)
        write(OUT/f'{key}-serve-model.json',model)
        report[key+'Count']=len(rows)
        report['evaluation'][key]=score(model)
        if key=='augmented': write(RES/'RawSwingButtonServes.json',model)
    first=json.loads((OUT/'单球原始记录.json').read_text())
    bank=[first]
    for label in dict.fromkeys(c['label'] for c in raw):
        base=next(c for c in raw if c['label']==label)
        if base['id']!=first['id']: bank.append(base)
        for angle,speed in [(-15,.85),(0,1.15),(15,1.),(15,1.15)]: bank.append(variant(base,angle,speed))
    write(RES/'RawSwingReplay.json',{'clips':bank})
    report['bankCount']=len(bank)
    report['rotationAxis']='device y'
    report['angles']=angles
    report['speeds']=speeds
    write(OUT/'发球模型评估.json',report)
    print(json.dumps(report['evaluation'],ensure_ascii=False),report['realCount'],report['augmentedCount'],len(bank))


def cross_session():
    """Rotate every original session out, including both physical-button collections."""
    cache = OUT / '原始按键窗口.json'
    raw = json.loads(cache.read_text()) if cache.is_file() else originals()
    items = [c for c in raw if c['role']=='serve'] + [c for c in reviewed() if c]
    items = [c for c in items if feature(c) is not None]
    real = np.array([feature(c) for c in items])
    augmented = []
    for c, base_feature in zip(items, real):
        group = [base_feature] + [feature(variant(c, angle, speed))
                                   for angle in (-15,0,15) for speed in (.85,1.,1.15)
                                   if (angle,speed)!=(0,1)]
        augmented.append(group)
    y = np.array([c['label'] for c in items])
    sessions = np.array([c['session'] for c in items])
    predictions = []
    for session in sorted(set(sessions)):
        test = sessions == session
        fold = {}
        for name, data in [('real',real[:,None,:]),('augmented',np.array(augmented))]:
            n = data.shape[1]
            m = fit(data[~test].reshape(-1,27),np.repeat(y[~test],n),np.repeat(sessions[~test],n))
            model = dict(labels=m.classes_.tolist(),weights=m.coef_.tolist(),bias=m.intercept_.tolist(),minimum=.55,margin=.15)
            fold[name] = probabilities(model,real[test])
        for i,j in enumerate(np.flatnonzero(test)):
            predictions.append(dict(id=items[j]['id'],label=y[j],session=session,
                                    anchor=items[j].get('anchor','volumeButton'),
                                    real=fold['real'][i],augmented=fold['augmented'][i]))
    write(OUT/'逐场交叉验证.json',predictions)
    for lab in LABELS:
        rows=[c for c in predictions if c['label']==lab]
        print(lab,len(rows),*[sum(r[name]==lab for r in rows) for name in ('real','augmented')])


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage',choices=('seed','train','cross-session'))
    stage=parser.parse_args().stage
    OUT.mkdir(parents=True,exist_ok=True)
    if stage=='seed':
        seed()
        plot(json.loads((OUT/'单球原始记录.json').read_text()),OUT/'真实挥拍曲线.png')
    elif stage=='train':
        train()
    else:
        cross_session()
