"""Map phone-uptime swing events onto the original clock of a capture movie."""

import csv
import json
import math
from bisect import bisect_left
from pathlib import Path
from statistics import mean


def clock_fit(path: Path) -> tuple[float, float]:
    """Return host = slope * phone + offset, following the capture app's ClockMap."""
    anchors = {}
    try:
        with path.open() as stream:
            for line in stream:
                point = json.loads(line)
                m0, p1, p2, m3 = (float(point[k]) for k in ("m0", "p1", "p2", "m3"))
                if not all(math.isfinite(t) for t in (m0, p1, p2, m3)):
                    raise ValueError("nonfinite clock anchor")
                host, phone = (m0 + m3) / 2, (p1 + p2) / 2
                rtt = (m3 - m0) - (p2 - p1)
                bucket = int(host / 10)
                if 0 <= rtt < 0.25 and (bucket not in anchors or rtt < anchors[bucket][0]):
                    anchors[bucket] = (rtt, phone, host)
    except (OSError, KeyError, TypeError, ValueError) as exc:
        raise ValueError(f"无法读取同步探测 {path}: {exc}") from exc
    if not anchors:
        raise ValueError(f"缺少有效同步探测 {path}")
    rows = sorted(anchors.values(), key=lambda a: a[1])
    if rows[-1][1] - rows[0][1] <= 10:
        return 1.0, rows[0][2] - rows[0][1]
    x, y = mean(a[1] for a in rows), mean(a[2] for a in rows)
    slope = sum((a[1] - x) * (a[2] - y) for a in rows) / sum((a[1] - x)**2 for a in rows)
    if not 0.998 <= slope <= 1.002:
        raise ValueError(f"手机与相机的时钟漂移过大 {path}")
    return slope, y - slope * x


def map_windows(movie: Path, windows: list[dict]) -> list[dict]:
    """Return segment-local movie seconds; centers outside its coverage are omitted.

    Each accepted row also preserves original phone bounds in phone_start,
    phone_center and phone_end. Fail closed if an in-segment center lacks frames.
    """
    if movie.name == "camera.mov":
        frames = movie.with_name("frames.csv")
        key = "t_mac"
        slope, offset = clock_fit(movie.with_name("clocks.jsonl"))
    elif movie.name == "game.mov":
        frames = movie.with_name("screen_frames.csv")
        key = "t_phone"
        slope, offset = 1.0, 0.0
    else:
        raise ValueError(f"未知录像时间基准 {movie}")
    clocks, pts = [], []
    try:
        with frames.open() as stream:
            for row in csv.DictReader(stream):
                t, sec = float(row[key]), float(row["video_s"])
                if not (math.isfinite(t) and math.isfinite(sec) and sec >= 0):
                    raise ValueError("invalid timestamp")
                if clocks and (t <= clocks[-1] or sec <= pts[-1]):
                    raise ValueError("frame timestamps out of order")
                clocks.append(t)
                pts.append(sec)
    except (OSError, KeyError, TypeError, ValueError) as exc:
        raise ValueError(f"无法读取帧索引 {frames}: {exc}") from exc
    if len(clocks) < 2:
        raise ValueError(f"帧索引为空或仅有单帧 {frames}")

    def seconds(t):
        i = bisect_left(clocks, t)
        if i == 0:
            return pts[0]
        if i == len(clocks):
            return pts[-1]
        fraction = (t - clocks[i-1]) / (clocks[i] - clocks[i-1])
        return pts[i-1] + fraction * (pts[i] - pts[i-1])

    mapped = []
    for window in windows:
        phone = [float(window[k]) for k in ("start", "center", "end")]
        if not all(math.isfinite(t) for t in phone) or not phone[0] <= phone[1] <= phone[2]:
            raise ValueError(f"挥拍窗口时间无效 {phone}")
        start, center, end = (slope * t + offset for t in phone)
        if not clocks[0] <= center <= clocks[-1]:
            continue
        i = bisect_left(clocks, center)
        if min(abs(clocks[i] - center), abs(clocks[max(0, i-1)] - center)) > 0.12:
            raise ValueError(f"挥拍中心 {phone[1]:.3f} 附近缺少视频帧 {frames}")
        mapped.append(dict(window, start=seconds(start), center=seconds(center), end=seconds(end),
                           phone_start=phone[0], phone_center=phone[1], phone_end=phone[2]))
    return mapped
