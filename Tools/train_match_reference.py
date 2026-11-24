"""Fit broadcast-view flight and elbow curves. Run with the project .venv on macOS."""
import argparse
import csv
import json
from pathlib import Path
import subprocess
from urllib.parse import quote

import cv2
import numpy as np
from scipy.optimize import minimize_scalar

REV = '4c88a65b25e45777eef1ed3f920eb085c515b047'
# Fixed-camera review intervals, consecutive flights with enough lateral span.
# Endpoints are approximate visual landmarks, not instrumented racket contact.
CLIPS = {'1_02_01': [(21,38),(61,89),(129,161)],
         '1_03_04': [(31,56),(57,88)],
         '1_06_06': [(4,28),(106,134)]}
# Near-court right-arm clips, center frame and horizontal crop center.
POSE = [('1_02_01',128,790,'overhead'),('1_03_04',56,810,'overhead'),
        ('1_02_01',61,505,'low')]


def progress(t, drag):
    return np.expm1(-drag*t)/np.expm1(-drag)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', nargs='?', type=Path, default=Path.home()/'Downloads/羽球比赛训练')
    root = parser.parse_args().folder
    media = root/'素材'
    media.mkdir(parents=True, exist_ok=True)
    pose_tool = root/'match-pose'
    subprocess.run(['xcrun','swiftc',str(Path(__file__).with_name('match_pose.swift')),'-o',str(pose_tool)],check=True)
    segments = []
    elbow_phases = []
    for clip, bounds in CLIPS.items():
        prefix = ('test data for demo/test data for demo' if clip=='1_03_04'
                  else 'test data/test data/professional_match')
        for remote, ext in [('video/'+clip+'.mp4','mp4'),('csv/'+clip+'_ball.csv','csv')]:
            target = media/(clip+'.'+ext)
            if not target.exists():
                url = 'https://raw.githubusercontent.com/AI-Dev-Learning/TrackNet-Badminton/'+REV+'/'+quote(prefix+'/'+remote)
                part = target.with_suffix('.part')
                subprocess.run(['curl','-fLs','--retry','2',url,'-o',str(part)],check=True)
                part.replace(target)
        cap = cv2.VideoCapture(str(media/(clip+'.mp4')))
        if not cap.isOpened():
            raise ValueError('Unreadable video '+clip)
        with (media/(clip+'.csv')).open() as data:
            marks = {int(r['Frame']):float(r['X']) for r in csv.DictReader(data) if int(r['Visibility'])}
        for begin,end in bounds:
            valid = [i for i in range(begin,end+1) if i in marks]
            a,b = valid[0],valid[-1]
            if len(valid)<8 or abs(marks[b]-marks[a])<45:
                continue
            t = (np.array(valid)-a)/(b-a)
            x = (np.array([marks[i] for i in valid])-marks[a])/(marks[b]-marks[a])
            segments.append((clip,a,b,t,x))
        for source,mid,cx,kind in POSE:
            if source != clip:
                continue
            folder=root/f'{clip}-{mid}'
            folder.mkdir(exist_ok=True)
            for frame in range(mid-11,mid+13):
                cap.set(cv2.CAP_PROP_POS_FRAMES,frame)
                ok,im=cap.read()
                if not ok: raise ValueError(f'Missing {clip} frame {frame}')
                cv2.imwrite(str(folder/f'{frame:04}.jpg'),im[310:700,cx-180:cx+180])
            with (folder/'joints.csv').open('w') as dest:
                subprocess.run([str(pose_tool),str(folder)],stdout=dest,check=True)
            points={}
            with (folder/'joints.csv').open() as rows:
                for r in csv.DictReader(rows):
                    points.setdefault(int(r['frame']),{})[r['joint']]=float(r['y'])
            for frame,j in points.items():
                if {'shoulder','hip','elbow'} <= j.keys() and j['hip']-j['shoulder']>20:
                    elbow_phases.append((clip,kind,frame-mid,(j['shoulder']-j['elbow'])/(j['hip']-j['shoulder'])))
        cap.release()
        # Review previous visible positions in the original camera coordinate system.
        cap = cv2.VideoCapture(str(media/(clip+'.mp4')))
        overlay = cv2.VideoWriter(str(root/(clip+'-轨迹.mp4')), cv2.VideoWriter_fourcc(*'mp4v'),
                                  cap.get(cv2.CAP_PROP_FPS),(1280,720))
        if not overlay.isOpened(): raise RuntimeError('Cannot write reference overlay')
        with (media/(clip+'.csv')).open() as rows:
            xy={int(r['Frame']):(round(float(r['X'])),round(float(r['Y']))) for r in csv.DictReader(rows) if int(r['Visibility'])}
        i=0
        while True:
            ok,img=cap.read()
            if not ok: break
            for j in range(max(1,i-8),i+1):
                if j in xy and j-1 in xy: cv2.line(img,xy[j-1],xy[j],(90,220,255),2)
            if i in xy: cv2.circle(img,xy[i],8,(50,225,70),2)
            cv2.putText(img,f'{clip}  frame {i}',(25,685),0,0.8,(255,255,255),2)
            overlay.write(img)
            i+=1
        cap.release()
        overlay.release()
    # Equal weight per training flight; hold out an entire rally.
    def loss(group,k):
        return float(np.mean([np.mean(abs(progress(t,k)-x)) for _,_,_,t,x in group]))
    train=[s for s in segments if s[0]!='1_06_06']
    held=[s for s in segments if s[0]=='1_06_06']
    fit=minimize_scalar(lambda k:loss(train,k),bounds=(0.01,6),method='bounded').x
    phases={}
    for lo,hi in [(-11,-5),(-2,3),(6,12)]:
        vals=[v for _,kind,f,v in elbow_phases if kind=='overhead' and lo<=f<=hi]
        phases[f'{lo}..{hi}']={'n':len(vals),'median':float(np.median(vals))}
    summary=dict(source_revision=REV,intervals=[s[:3] for s in segments],screen_x_drag=fit,
                 heldout_linear_mae=loss(held,0.0001),heldout_fit_mae=loss(held,fit),
                 overhead_elbow_relative_to_shoulder=phases)
    (root/'比赛拟合结果.json').write_text(json.dumps(summary,indent=2,ensure_ascii=False))
    print(json.dumps(summary,ensure_ascii=False))

if __name__=='__main__':
    main()
