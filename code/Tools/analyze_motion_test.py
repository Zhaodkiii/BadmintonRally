"""Summarize one or more JSON files shared from the iPhone motion test."""
import argparse
import json
import math
from pathlib import Path


def summarize(trace):
    print(f"{trace['target']} | {trace['state']} | 曲线 {trace['curveVersion']}")
    frames = trace["frames"]
    events = trace["events"]
    for window in (event for event in events if event["kind"] == "window"):
        start, end = window["time"], window["end"]
        samples = [frame for frame in frames if start <= frame["time"] <= end]
        nearby = [event for event in events if event["kind"] == "candidate"
                  and start - .5 <= event["time"] <= end + .36]
        print(f"第 {window['round']} 拍")
        if samples:
            peak = max(samples, key=lambda frame: math.hypot(*frame["rotation"]))
            trigger = peak.get("trigger")
            peak_text = f"{math.hypot(*peak['rotation']):.2f} rad/s"
            threshold = f"{trigger:.2f} rad/s" if trigger is not None else "无"
            armed = sum(frame["armed"] or frame["tracking"] for frame in samples)
            print(f"  {len(samples)} 帧，{armed} 帧已就位或在跟踪，峰值 {peak_text}，峰值时门槛 {threshold}")
        else:
            print("  窗口内没有 IMU 样本")
        for event in nearby:
            offset = event["time"] - start
            time_status = "窗口内" if 0 <= offset <= end - start else "窗口外"
            print(f"  {offset:+.3f}s {time_status}：{event['text']}，比赛 {event.get('game', '—')}，曲线 {event.get('curve', '—')}")
            for key, label in (("score", "曲线相似度"), ("margin", "曲线分差"),
                               ("directionScore", "方向相似度"), ("directionMargin", "方向分差")):
                if key in event:
                    print(f"    {label} {event[key]:.3f}")
        for event in events:
            if event["kind"] == "result" and event.get("round") == window["round"]:
                print(f"  {event['text']}")
    if not any(event["kind"] == "window" for event in events):
        print("尚未进入正式挥拍；最近的校准记录：")
        for event in [event for event in events if event["kind"] in {"status", "candidate"}][-5:]:
            print(f"  {event['text']}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("files", type=Path, nargs="+")
    args = parser.parse_args()
    for file in args.files:
        with file.open(encoding="utf-8") as source:
            summarize(json.load(source))
