"""Simulate rigid grip and timing perturbations; evaluate a conservative smash detector."""
import argparse
import json
from pathlib import Path
from collections import Counter

import numpy as np
from sklearn.linear_model import LogisticRegression
from sklearn.preprocessing import StandardScaler

from prepare_raw_swing import ROOT, write
from train_raw_returns import physical, support, SESSIONS, x as raw_features

OUT = ROOT/'data/正式对局验收/P040/挥拍训练'
# roll/pitch/yaw in degrees, virtual phone displacement in original device axes (m),
# uniform path playback rate, and independent button delay in replay seconds.
VARIATIONS = [
    ([12,-8,9], [.012,-.018,.006], .88, -.025),
    ([-9,14,-12], [-.013,.014,.004], 1.14, .025),
    ([8,6,-16], [.006,.021,-.011], 1.05, -.010),
    ([-15,-7,11], [-.017,-.009,.008], .96, .012),
]


def transform(row, index):
    angle, offset, tempo, delay=VARIATIONS[index]
    a=np.asarray(row['frames'])
    src=a[:,0]-a[0,0]
    t=np.arange(0,src[-1]/tempo,.01)
    w=a[:,1:4]
    def backward_derivative(values):
        dt=np.diff(src)
        return np.vstack([np.zeros(3),np.diff(values,axis=0)/dt[:,None]])
    # Move a point on a rigid grip before changing device axes. A causal derivative
    # and modest offsets avoid using post-button samples to generate earlier signals.
    alpha=backward_derivative(w)
    accel=a[:,4:7]+(np.cross(alpha,offset)+np.cross(w,np.cross(w,offset)))/9.80665
    roll,pitch,yaw=np.deg2rad(angle)
    cr,cp,cy=np.cos([roll,pitch,yaw])
    sr,sp,sy=np.sin([roll,pitch,yaw])
    rotation=np.array([[cy*cp,cy*sp*sr-sy*cr,cy*sp*cr+sy*sr],
                       [sy*cp,sy*sp*sr+cy*cr,sy*sp*cr-cy*sr],
                       [-sp,cp*sr,cp*cr]])
    data=np.column_stack([w*tempo@rotation.T, accel*tempo**2@rotation.T, a[:,7:10]@rotation.T])
    vals=np.column_stack([np.interp(t*tempo,src,col) for col in data.T])
    gravity=vals[:,6:9]
    gravity/=np.maximum(np.linalg.norm(gravity,axis=1,keepdims=True),1e-9)
    press=(row['press']-a[0,0])/tempo+delay
    assert t[0]<=press<=t[-1]
    variant={**row,'id':row['id']+f'_P040v{index+1}','parent':row['id'],'press':press,
             'frames':np.column_stack([t,vals]).tolist(),
             'sensorTransform':dict(anglesDegrees=angle,offsetMeters=offset,
                                    tempo=tempo,buttonDelaySeconds=delay)}
    if 'fixture' in row:
        variant['fixture']={**row['fixture'],'buttonOffset':row['fixture']['buttonOffset']+delay}
    return variant


def replay_banks():
    ref=ROOT/'data/正式对局验收/P039/原机复盘/P039-replay.json'
    def mark_service(row):
        # B688 began with one own serve. After its sole incoming rally stroke (#2)
        # every next incoming was the opponent's serve; the near side never returned one.
        return {**row,'fixture':{**row['fixture'],'service':row['id']!='B688-#2'}}
    fixtures=[mark_service(c) for c in json.loads(ref.read_text())['clips']]
    batch=[item for row in fixtures for item in [row,*[transform(row,i) for i in range(3)]]]
    write(OUT/'P039-replay.json',{'clips':batch})
    path=ROOT/'code/Clients/iOS/Resources/RawSwingReplay.json'
    sources=[c for c in json.loads(path.read_text())['clips'] if 'parent' not in c]
    full=[item for row in sources for item in [row,*[transform(row,i) for i in range(4)]]]
    write(OUT/'P038-replay.json',{'clips':full})
    all_returns=[mark_service(c) for c in json.loads((ref.parent/'P039-全部22次接球.json').read_text())['clips']]
    continuous=[c for c in full if c['role']=='serve']
    for repetition in range(5):
        for index,row in enumerate(all_returns):
            method=(repetition+index)%5
            continuous.append(row if method==0 else transform(row,method-1))
    write(OUT/'P040-replay.json',{'clips':continuous})
    print('fixtures',len(batch),'full',len(full),'continuous',len(continuous))



def primitive(row):
    """Signed wrist rotation projected onto gravity, and gravity-independent swing magnitude."""
    a=np.asarray(row['frames'])
    dt=a[:,0]-row['press']
    v=[]
    for lo,hi in [(-.24,-.16),(-.16,-.08),(-.08,0)]:
        q=a[(dt>lo)&(dt<=hi)]
        w,acc,g=q[:,1:4],q[:,4:7],q[:,7:10]
        g=g/np.maximum(np.linalg.norm(g,axis=1,keepdims=True),.1)
        v.extend([np.log1p(np.linalg.norm(w,axis=1)).mean(),np.log1p(np.linalg.norm(acc,axis=1)).mean(),
                  np.arcsinh(np.sum(w*g,axis=1)/4).mean(),np.arcsinh(np.sum(acc*g,axis=1)).mean()])
    return np.array(v)


def angular_path(row,lo,hi):
    q=np.asarray(row['frames'])
    t=q[:,0]-row['press']
    grid=np.linspace(lo,hi,17)
    w=np.column_stack([np.interp(grid,t,col) for col in q[:,1:4].T])
    speed=np.linalg.norm(w,axis=1)
    return float(np.sum(.5*(speed[:-1]+speed[1:])*np.diff(grid)))


def experiments():
    from sklearn.linear_model import Ridge
    primary=[r for s in SESSIONS for r in physical(s) if raw_features(r) is not None]
    auxiliary=[r for r in support() if raw_features(r) is not None]
    originals=primary+auxiliary
    expanded=[item for r in originals for item in [r,*[transform(r,i) for i in range(4)]]]
    stable=np.array([primitive(r) for r in originals])
    X=np.array([primitive(r) for r in expanded])
    groups=np.array([r['session'] for r in expanded])
    source_groups=np.array([r['session'] for r in originals])
    labels=np.array([r['label']=='扣杀' for r in expanded])
    true=np.array([r['label']=='扣杀' for r in originals])

    def binary(allowed):
        mask=np.isin(groups,list(allowed))
        scaler=StandardScaler().fit(X[mask])
        m=LogisticRegression(C=.3,class_weight='balanced',max_iter=300).fit(scaler.transform(X[mask]),labels[mask])
        return scaler,m

    def threshold_for(train_sessions):
        # Fit once per calibration group, only on remaining outer-training sessions.
        # No held recording or its generated relatives participate in threshold selection.
        scores=[]
        for g in train_sessions:
            if not any((source_groups==g)&~true):
                continue
            if len(set(labels[np.isin(groups,list(train_sessions-{g}))]))<2:
                continue
            sc,m=binary(train_sessions-{g})
            score=m.predict_proba(sc.transform(stable[(source_groups==g)&~true]))[:,1]
            scores.extend(score)
        return min(1.,max([.8,*scores])+.000001)

    regress_x=X[:,:8]
    param_y=np.array([angular_path(r,-.08,0) for r in expanded])
    regression=[]
    decisions=[]
    sessions=set(groups)
    for held in SESSIONS:
        allow=sessions-{held}
        cutoff=threshold_for(allow)
        sc,m=binary(allow)
        mask=source_groups==held
        probs=m.predict_proba(sc.transform(stable[mask]))[:,1]
        for idx,p in zip(np.where(mask)[0],probs):
            decisions.append(dict(id=originals[idx]['id'],label=originals[idx]['label'],
                                  score=float(p),cutoff=cutoff,
                                  smash=bool(p>=cutoff),fixedSmash=bool(p>=.8)))
        train=groups!=held
        norm=StandardScaler().fit(regress_x[train])
        reg=Ridge(alpha=20).fit(norm.transform(regress_x[train]),param_y[train])
        estimates=np.maximum(0.,reg.predict(norm.transform(stable[mask,:8])))
        for idx,p in zip(np.where(mask)[0],estimates):
            row=originals[idx]
            regression.append(dict(id=row['id'],label=row['label'],expected=angular_path(row,-.08,0),
                                   persistence=angular_path(row,-.16,-.08),prediction=float(p)))
    sc,m=binary(sessions)
    norm=StandardScaler().fit(regress_x)
    reg=Ridge(alpha=20).fit(norm.transform(regress_x),param_y)
    parameters=dict(smash=dict(mean=sc.mean_.tolist(),scale=sc.scale_.tolist(),
                        weights=m.coef_[0].tolist(),bias=float(m.intercept_[0]),
                        threshold=threshold_for(sessions)),
                    angularTravel=dict(mean=norm.mean_.tolist(),scale=norm.scale_.tolist(),
                        weights=reg.coef_.tolist(),bias=float(reg.intercept_),unit='rad, -80 ms through button'))
    write(OUT/'候选物理模型.json',parameters)
    write(OUT/'扣杀拒识折外结果.json',decisions)
    write(OUT/'末段转角折外估计.json',regression)
    for key in ['fixedSmash','smash']:
        print(key,sum(r[key] and r['label']=='扣杀' for r in decisions),sum(r[key] and r['label']!='扣杀' for r in decisions))
    for key in ['persistence','prediction']:
        errors=[abs(r['expected']-r[key]) for r in regression]
        print(key,np.mean(errors),np.median(errors))


def score_unseen():
    """Use physically measured angular travel as target, with no shot-intent assumptions."""
    import csv
    from prepare_raw_swing import INPUT, window
    from train_raw_returns import CHANNELS
    m=json.loads((OUT/'候选物理模型.json').read_text())
    model=m['angularTravel']
    results={}
    for prefix in ['B68865BF','DAB31C4E']:
        folder,=INPUT.glob(prefix+'*')
        def read(name):
            with (folder/'分析'/name).open(encoding='utf-8-sig') as f:
                return list(csv.DictReader(f))
        mat=np.array([[float(r[k]) for k in ['t_phone',*CHANNELS]] for r in read('motion.csv')])
        events=read('events.csv')
        keys={e['gameTime']:float(e['time']) for e in events if e['kind']=='manualContact'}
        rows=[]
        for e in events:
            if e['kind']!='judgment' or e['text'] not in ['late','outOfReach','tooHigh']:
                continue
            t=keys[e['gameTime']]
            c=window(mat,t,folder.name,'unknown','physical-volume-key')
            if not c:
                rows.append(dict(time=t,missing=True))
                continue
            feat=primitive(c)
            normalized=(feat[:8]-model['mean'])/model['scale']
            p=max(0.,model['bias']+normalized@model['weights'])
            rows.append(dict(time=t,prediction=float(p),expected=angular_path(c,-.08,0),
                             persistence=angular_path(c,-.16,-.08),intent=None))
        scored=[r for r in rows if 'expected' in r]
        results[folder.name]=dict(records=rows,metrics={k:float(np.mean([abs(r['expected']-r[k]) for r in scored]))
                                      for k in ['persistence','prediction']})
        print('independent',folder.name,len(scored),results[folder.name]['metrics'])
    write(OUT/'未训练实战末段转角验证.json',results)
    from PIL import Image, ImageDraw, ImageFont
    image=Image.new('RGB',(1120,680),'white')
    draw=ImageDraw.Draw(image)
    font=ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc',20)
    title=ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc',26)
    draw.text((36,20),'Angular travel in the last 80 ms before each return button (rad)',font=title,fill='#162533')
    for idx,(sid,group) in enumerate(results.items()):
        top=100+idx*277
        rows=[r for r in group['records'] if 'expected' in r]
        metrics=group['metrics']
        draw.text((54,top-11),f"{sid[:8]}   |   {len(rows)} returns   |   MAE   persistence {metrics['persistence']:.3f}   model {metrics['prediction']:.3f} rad",font=font,fill='#263c48')
        ceiling=max(1.,np.ceil(max(r[k] for r in rows for k in ['expected','persistence','prediction'])*2)/2)
        def coords(i,val):
            return (88+i*974/(len(rows)-1),top+211-(val/ceiling)*165)
        for val in (0,ceiling/2,ceiling):
            draw.line([coords(0,val),coords(len(rows)-1,val)],fill='#e1e7ec')
            draw.text((31,coords(0,val)[1]-10),f'{val:.1f}',font=font,fill='#536169')
        for k,color in [('persistence','#b5a99a'),('prediction','#168a75'),('expected','#243b75')]:
            points=[coords(i,r[k]) for i,r in enumerate(rows)]
            draw.line(points,fill=color,width=3)
            for u,v in points:
                draw.ellipse((u-3,v-3,u+3,v+3), fill=color)
        for i in (0,len(rows)-1):
            draw.text((coords(i,0)[0]-5,top+217),str(i+1),fill='#536169',font=font)
    for i,(name,color) in enumerate([('Recorded IMU','#243b75'),('Predicted','#168a75'),('Persistence baseline','#b5a99a')]):
        draw.text((40+i*300,625),name,fill=color,font=font)
    image.save(OUT/'两局独立实测转角.png')



if __name__=='__main__':
    OUT.mkdir(parents=True,exist_ok=True)
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", choices=["replay","train","unseen"])
    args=parser.parse_args()
    if args.stage=="replay":
        replay_banks()
    elif args.stage=="train":
        experiments()
    else:
        score_unseen()
