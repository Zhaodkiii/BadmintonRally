"""Align a train_curves run with camera PTS and independently estimate 2D wrist speed."""
import argparse
import csv
import json
import subprocess
from pathlib import Path

import numpy as np
from train_curves import CHANNELS, clock_fit


def records(file):
    with file.open(encoding='utf-8-sig') as stream:
        return list(csv.DictReader(stream))


def audit(root, run, binary):
    results = []
    for r in records(run/'review.csv'):
        folder = root/r['session']
        samples = records(folder/'samples.csv')
        frames = records(folder/'frames.csv')
        times = np.array([float(f['t_mac']) for f in frames])
        t = np.array([float(s['t_phone']) for s in samples])
        signals = np.array([[float(s[c]) for c in CHANNELS] for s in samples])
        speed = np.linalg.norm(signals[:, :3], axis=1)
        peak = int(r['peak'])
        left = right = peak
        while left > int(r['start']) and speed[left-1] >= .35*speed[peak]:
            left -= 1
        while right < int(r['end']) and speed[right+1] >= .35*speed[peak]:
            right += 1
        slope, offset = clock_fit(folder/'clocks.jsonl')
        host = slope*t[peak]+offset
        idx = int(np.argmin(abs(times-host)))
        pts = float(frames[idx]['video_s'])
        hand = json.loads((folder/'manifest.json').read_text())['hand']
        output = subprocess.check_output([str(binary), str(folder/'camera.mov'), str(pts), hand], text=True)
        points = sorted(set(tuple(map(float,l.split())) for l in output.splitlines()))
        velocities = []
        for a,b in zip(points,points[1:]):
            dt = b[0]-a[0]
            if .015 < dt < .055:
                velocities.append((np.hypot(b[1]-a[1], b[2]-a[2])/dt,(b[0]+a[0])/2))
        delta = round((max(velocities)[1]-pts)*1000) if len(velocities)>=6 else None
        results.append(dict(session=r['session'], label=r['label'], speed=r['speed'], split=r['split'],
            prediction=r['held_prediction'], imu_peak_rad_s=round(speed[peak],2), accel_at_peak_g=round(np.linalg.norm(signals[peak,3:]),3),
            main_width_ms=round((t[right]-t[left])*1000), phone_peak=t[peak], video_s=pts,
            alignment_ms=round((times[idx]-host)*1000,1), wrist_frames=len(points), wrist_peak_delta_ms=delta,
            competing_ratio=r['competing_ratio']))
    with (run/'video_peaks.csv').open('w',newline='',encoding='utf-8-sig') as out:
        writer=csv.DictWriter(out,fieldnames=results[0]);writer.writeheader();writer.writerows(results)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for key in ('root','run','binary'):parser.add_argument(key,type=Path)
    args=parser.parse_args()
    audit(args.root,args.run,args.binary)
