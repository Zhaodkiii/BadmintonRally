"""Write a round report and pair each real example with its corresponding game replay."""
import argparse
import csv
import json
from html import escape
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('round', type=Path)
parser.add_argument('index', type=Path)
args = parser.parse_args()
folder = args.round.resolve()
index = args.index.resolve()
clips = json.loads(index.read_text())
with (folder / '回放.csv').open() as stream:
    rows = list(csv.DictReader(stream))
sample = {r['回法']: r for r in rows if r['左手'] == 'false' and r['帧率'] == '60'}
assert len(rows) == 162 and len(sample) == 27
hits = [r for r in rows if r['触球'] == 'true']
lines = [f'# {folder.name} 测试报告', '',
         f'九种来球、27种模拟输入、双持机手、30/60/120 Hz。按键触球 {len(hits)}/{len(rows)}，预计过网 {sum(r["过网"]=="true" for r in hits)}/{len(rows)}。',
         '', '表内为右手60 Hz的模拟结果。握点跳变以人物根节点为参照，取按键前一帧至按键帧。落深从球网向对方底线计量；触网时取网面。测试输入直接送入游戏，不含手机采样或真实玩家意图推断。',
         '', '|场景|模拟回法|游戏判断|落深 m|横向 m|最高点 m|握点跳变 cm|预计过网|','|---|---|---|---:|---:|---:|---:|---|']
for name, r in sample.items():
    if r['触球'] != 'true':
        lines.append(f'|{r["场景"]}|{name}|未触球||||||')
        continue
    nums = [float(r[k]) for k in ['距网落点米', '横向落点米', '最高米']]
    lines.append('|{}|{}|{}|{:.2f}|{:.2f}|{:.2f}|{:.1f}|{}|'.format(
        r['场景'], name, r['实际回法'], *nums, 100*float(r['触球握点跳变米']), '是' if r['过网']=='true' else '否'))
if hits:
    worst = max(hits,key=lambda r:float(r['触球握点跳变米']))
    lines += ['', f'全矩阵握点跳变最大项为 {worst["回法"]}，{worst["帧率"]} Hz，左手={worst["左手"]}，{100*float(worst["触球握点跳变米"]):.1f} cm。不同帧率的单帧时长不同。']
# Include the late recovery: a short contact-centred window missed the old
# backhand-drop reset at 567 ms.
if (folder/'收拍.csv').exists():
    with (folder/'收拍.csv').open() as stream:
        recovery = list(csv.DictReader(stream))
    lines += ['', '## 收拍连续性', '', '右手 60 Hz，按键后 117–800 ms。每个动作单独取相邻两帧拍头位移最大值。', '',
              '|回法|最大单帧位移 cm|发生在击球后 ms|', '|---|---:|---:|']
    for name in sample:
        window = [r for r in recovery if r['回法']==name and 0.116 <= float(r['击后秒']) <= 0.801]
        if window:
            peak = max(window, key=lambda r: float(r['拍头位移米']))
            lines.append(f'|{name}|{100*float(peak["拍头位移米"]):.2f}|{1000*float(peak["击后秒"]):.0f}|')
if (folder/'腿长.csv').exists():
    with (folder/'腿长.csv').open() as stream:
        legs = list(csv.DictReader(stream))
    lines += ['', '## 双腿骨段', '']
    for segment in ['大腿', '小腿']:
        lo = min(float(r[segment+'最短米']) for r in legs)
        hi = max(float(r[segment+'最长米']) for r in legs)
        lines.append(f'{segment}在移动和挥拍过程中的全组长度范围为 {lo*100:.2f}–{hi*100:.2f} 厘米。')
(folder/'测试报告.md').write_text('\n'.join(lines)+'\n')
html = ['<!doctype html><meta charset=utf-8><title>逐段比赛与游戏复核</title><style>body{font:16px system-ui;max-width:1100px;margin:auto;padding:20px}section{border-top:1px solid #aaa;padding:12px 0}video,img{width:48%;vertical-align:middle}</style>',f'<h1>{escape(folder.name)} · 逐段比赛与游戏复核</h1>']
for c in clips:
    name = c['目标回法']
    r = sample[name]
    src = (index.parent/c['片段']).resolve()
    assert src.is_file()
    game = folder/'连续画面'/(name+'.mp4')
    html += [f'<section><h2>{c["编号"]}. {escape(name)}</h2><p>{escape(c["状态"])} · 真人动作区间 {c["片段内动作开始秒"]:.2f}–{c["片段内动作结束秒"]:.2f} 秒 · 游戏判为 {escape(r["实际回法"] or "未触球")}</p>',
             f'<video controls preload="none" src="{src.as_uri()}#t={max(0,c["片段内动作开始秒"]-.3):.3f}"></video>',
             f'<video controls muted preload="none" src="{game.as_uri()}"></video>' if game.exists() else f'<img loading="lazy" src="{(folder/(name+".jpg")).as_uri()}">',
             f'<p>{escape(c["观察说明"])}</p></section>']
(folder/'逐段对照.html').write_text('\n'.join(html))
