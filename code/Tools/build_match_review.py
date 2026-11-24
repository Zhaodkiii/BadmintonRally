"""Build an offline two-round review and a frame-accurate collection of the later round."""
import argparse
import csv
from collections import defaultdict
import json
import os
from pathlib import Path
import shutil
import subprocess
from urllib.parse import quote

import cv2
import imageio_ffmpeg
import numpy as np
from PIL import Image, ImageDraw, ImageFont


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def inspect_video(path, metadata=None):
    cap = cv2.VideoCapture(str(path))
    count = 0
    fps = cap.get(cv2.CAP_PROP_FPS)
    try:
        while cap.grab():
            ok, frame = cap.retrieve()
            if not ok or frame is None:
                raise ValueError(f"视频无法解码到第 {count} 帧 {path}")
            count += 1
    finally:
        cap.release()
    if count == 0 or fps <= 0:
        raise ValueError(f"无可用视频帧 {path}")
    if metadata and (count != metadata['frames'] or abs(fps-metadata['fps']) > .01
                     or not 0 <= metadata['contactFrame'] < count):
        raise ValueError(f"帧数、帧率或击球位置不匹配 {path}")
    return count, fps


def relative(path, output):
    return quote(os.path.relpath(path, output), safe="/-._~")


def collect(rounds, index, output):
    examples = defaultdict(list)
    for ref in read_json(index):
        path = index.parent/ref['片段']
        count, fps = inspect_video(path)
        start, end = ref['片段内动作开始秒'], ref['片段内动作结束秒']
        if not 0 <= start <= end <= count/fps + 1/fps:
            raise ValueError(f"录像区间超出视频时长 {path}")
        examples[ref['目标回法']].append(dict(url=relative(path,output), number=ref['编号'],
                    start=start, end=end, status=ref['状态'], fps=fps, frames=count))
    table = []
    with (rounds[1]/'回放.csv').open(encoding="utf-8-sig") as stream:
        order = [row['回法'] for row in csv.DictReader(stream)
                 if row['帧率']=='60' and row['左手']=='false']
    if len(set(order)) != len(order) or set(order) != set(examples):
        raise ValueError("比赛索引与回放动作清单不一致")
    for name in order:
        media = []
        for folder in rounds:
            path = folder/'实速'/f'{name}.mp4'
            meta = read_json(path.with_suffix('.json'))
            inspect_video(path, meta)
            if meta['action']!=name:
                raise ValueError(f"错误的动作元数据 {path}")
            media.append(dict(url=relative(path,output),frames=meta['frames'],fps=meta['fps'],
                              hit=meta['contactFrame'],scene=meta['scene']))
        if media[0]['scene']!=media[1]['scene']:
            raise ValueError(f"两轮的场景不一致 {name}")
        table.append(dict(action=name,scene=media[1]['scene'],games=media,refs=examples[name]))
    return table


def banner(width, height, font, name, tag):
    image = Image.new("RGB",(width,height),(20,31,37))
    draw = ImageDraw.Draw(image)
    draw.text((14,height/2),name,anchor="lm",fill="white",font=font)
    draw.text((width-14,height/2),tag,anchor="rm",fill="#ffc455" if tag=="击球帧" else "#aeccc9",font=font)
    return cv2.cvtColor(np.asarray(image),cv2.COLOR_RGB2BGR)


def compile_reel(round_dir, target, records, font_path):
    first = round_dir/'实速'/f"{records[0]['action']}.mp4"
    cap = cv2.VideoCapture(str(first))
    width,height = int(cap.get(3)),int(cap.get(4))
    cap.release()
    fps = records[0]['games'][1]['fps']
    band = max(36,(height//11)//2*2)
    font = ImageFont.truetype(str(font_path), max(18,band//2))
    temp = target.with_suffix('.partial.mp4')
    ffmpeg = shutil.which("ffmpeg") or imageio_ffmpeg.get_ffmpeg_exe()
    command = [ffmpeg,"-nostdin","-hide_banner","-loglevel","error","-y","-f","rawvideo",
               "-pix_fmt","bgr24","-s",f"{width}x{height+band}","-r",str(fps),"-i","-",
               "-an","-c:v","libx264","-preset","veryfast","-crf","19","-pix_fmt",
               "yuv420p","-movflags","+faststart",str(temp)]
    total = 0
    try:
        with subprocess.Popen(command,stdin=subprocess.PIPE) as encoder:
            try:
                for i,record in enumerate(records,1):
                    meta = record['games'][1]
                    if meta['fps']!=fps: raise ValueError("合辑需要统一时基")
                    record['reelStart'] = total/fps
                    cap = cv2.VideoCapture(str(round_dir/'实速'/f"{record['action']}.mp4"))
                    label = f"{i:02}    {record['scene']}  ·  {record['action']}"
                    overlays = [banner(width,band,font,label,s) for s in ('准备','击球帧','随挥')]
                    try:
                        for j in range(meta['frames']):
                            ok,frame = cap.read()
                            if not ok or frame.shape[:2]!=(height,width):raise ValueError(label)
                            state = 0 if j<meta['hit'] else 1 if j==meta['hit'] else 2
                            encoder.stdin.write(frame.tobytes())
                            encoder.stdin.write(overlays[state].tobytes())
                            total += 1
                    finally:cap.release()
            finally:
                encoder.stdin.close()
            if encoder.wait():raise RuntimeError("合辑编码失败")
        count, rate = inspect_video(temp)
        if total!=count or abs(fps-rate)>.01:raise ValueError("合辑帧数校验失败")
        temp.replace(target)
    finally:
        temp.unlink(missing_ok=True)
    return total


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--before",type=Path,required=True)
    ap.add_argument("--after",type=Path,required=True)
    ap.add_argument("--index",type=Path,default=Path(__file__).resolve().parents[2] / 'data/羽毛球比赛视频/接球动作片段精选/片段索引.json')
    ap.add_argument("--output",type=Path,required=True)
    ap.add_argument("--labels",nargs=2,default=["第13轮","第14轮"])
    ap.add_argument("--font",type=Path,default=Path('/System/Library/Fonts/STHeiti Medium.ttc'))
    args=ap.parse_args()
    args.output.mkdir(parents=True,exist_ok=True)
    table=collect([args.before,args.after],args.index,args.output)
    reel=args.output/f'{args.labels[1]}动作合辑.mp4'
    total=compile_reel(args.after,reel,table,args.font)
    template=Path(__file__).with_name('match_review.html').read_text()
    data=json.dumps(dict(rows=table,labels=args.labels,reel=relative(reel,args.output)),
                    ensure_ascii=False).replace('<','\\u003c')
    target=args.output/'运行录像复盘.html'
    temp=target.with_suffix('.partial.html')
    temp.write_text(template.replace('/*DATA*/',data))
    temp.replace(target)
    print(f"{len(table)} 个动作，合辑校验 {total} 帧。{target}")

if __name__=='__main__':
    main()
