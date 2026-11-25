"""Frame-accurate compaction for the H.264 camera/screen MOV captures (FFmpeg)."""

import bisect
import json
import math
import os
from pathlib import Path
import subprocess
import tempfile


def _run(args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        raise ValueError(result.stderr.strip() or f"{args[0]} failed")
    return result.stdout


def probe(path):
    """Times exposed to callers are relative to the video's first visible frame."""
    raw = json.loads(_run(["ffprobe", "-v", "error", "-show_streams", "-of", "json", str(path)]))
    videos = [s for s in raw["streams"] if s["codec_type"] == "video"]
    if len(videos) != 1:
        raise ValueError(f"Expected one video stream in {path}")
    video = videos[0]
    rotation = next((item["rotation"] for item in video.get("side_data_list", [])
                     if "rotation" in item), 0)
    return dict(duration=float(video["duration"]), start=float(video.get("start_time", 0)),
                width=video["width"], height=video["height"], rotation=rotation,
                audio=sum(s["codec_type"] == "audio" for s in raw["streams"]),
                pixel_format=video["pix_fmt"])


def _packets(path):
    data = _run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_packets",
                 "-show_entries", "packet=pts_time,flags", "-of", "csv=p=0", str(path)])
    packets = []
    for line in data.splitlines():
        fields = line.split(",")
        if len(fields) >= 2 and "D" not in fields[1] and fields[0] != "N/A":
            packets.append((round(float(fields[0]) * 1_000_000), "K" in fields[1]))
    packets.sort()
    if not packets:
        raise ValueError(f"No visible video samples in {path}")
    origin = packets[0][0]
    return [p - origin for p, _ in packets], [p - origin for p, key in packets if key]


def _sum_expression(terms):
    # Balanced expressions also work on long sessions with hundreds of windows.
    while len(terms) > 1:
        terms = [f"({terms[i]}+{terms[i+1]})" if i + 1 < len(terms) else terms[i]
                 for i in range(0, len(terms), 2)]
    return terms[0]


def compact_video(source, destination, intervals):
    """Encode the union of [start,end) ranges; keep VFR cadence and track rotation.

    Use separate paths. Publish the result only after decoding and checking its
    frame timestamps against every selected source sample. Times in seconds.
    """
    source, destination = Path(source), Path(destination)
    if source.resolve() == destination.resolve() or destination.exists():
        raise FileExistsError(destination)
    info = probe(source)
    pts, keys = _packets(source)
    if not keys or pts[-1] >= round(info["duration"] * 1_000_000):
        raise ValueError("Incomplete source video timing")
    limit = round(info["duration"] * 1_000_000)
    ranges = []
    for start, end in sorted(intervals):
        if not (math.isfinite(start) and math.isfinite(end) and end > start):
            raise ValueError(f"Invalid video interval {(start, end)}")
        a, b = max(0, round(start * 1e6)), min(limit, round(end * 1e6))
        if b <= a:
            continue
        first = max(0, bisect.bisect_right(pts, a) - 1)
        stop = bisect.bisect_left(pts, b)
        if ranges and first <= ranges[-1][1]:
            ranges[-1] = ranges[-1][0], max(ranges[-1][1], stop)
        else:
            ranges.append((first, stop))
    if not ranges:
        raise ValueError("No selected frames in video")

    select, jumps, expected, segments = [], [], [], []
    offset = previous_end = 0
    for first, stop in ranges:
        start, end = pts[first], pts[stop] if stop < len(pts) else limit
        select.append(f"between(n,{first},{stop - 1})")
        jumps.append(f"{start - previous_end}*gte(N,{len(expected)})")
        expected.extend(p - start + offset for p in pts[first:stop])
        segments.append(dict(source_start=start/1e6, source_end=end/1e6,
                             output_start=offset/1e6, output_end=(offset+end-start)/1e6,
                             frames=stop-first, source_first_frame=first,
                             preceding_keyframe=keys[max(0, bisect.bisect_right(keys, start)-1)]/1e6))
        offset += end - start
        previous_end = end

    filters = [f"[0:v:0]select='{_sum_expression(select)}',settb=1/1000000,"
               f"setpts='PTS-({_sum_expression(jumps)})'[v]"]
    maps = ["-map", "[v]"]
    for channel in range(info["audio"]):
        parts = []
        for i, seg in enumerate(segments):
            label = f"a{channel}_{i}"
            filters.append(f"[0:a:{channel}]atrim=start={seg['source_start']}:end={seg['source_end']},"
                           f"asetpts=PTS-STARTPTS[{label}]")
            parts.append(f"[{label}]")
        filters.append(f"{''.join(parts)}concat=n={len(parts)}:v=0:a=1[a{channel}]")
        maps += ["-map", f"[a{channel}]"]

    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent) as tmp:
        output = Path(tmp) / ("output" + destination.suffix)
        # The final encoded packet can arrive after its presentation timestamp.
        # Read through the next keyframe before flushing the decoder.
        last = segments[-1]["source_end"]
        next_key = bisect.bisect_right(keys, round(last * 1e6))
        read_to = min(info["duration"], keys[next_key] / 1e6 + 1) if next_key < len(keys) else info["duration"]
        final_duration = offset - expected[-1]
        duration_filter = f"setts=duration='if(eq(N,{len(expected)-1}),{final_duration},DURATION)'"
        command = ["ffmpeg", "-nostdin", "-hide_banner", "-v", "error", "-xerror",
                   "-threads", "4", "-noautorotate", "-to", str(read_to), "-i", str(source), "-filter_complex", ";".join(filters),
                   *maps, "-c:v", "libx264", "-threads:v", "4", "-preset", "veryfast",
                   "-crf", "22", "-bf", "0", "-force_key_frames",
                   ",".join(str(seg["output_start"]) for seg in segments),
                   "-bsf:v", duration_filter,
                   "-fps_mode", "vfr", "-enc_time_base:v", "1:1000000",
                   "-video_track_timescale", "1000000", "-c:a", "aac", "-movflags", "+faststart",
                   str(output)]
        _run(command)
        actual, output_keys = _packets(output)
        out_info = probe(output)
        if len(expected) != len(actual) or any(abs(a-b) > 2 for a,b in zip(actual, expected)):
            raise ValueError(f"Selected frame timestamps differ ({len(expected)} expected, {len(actual)} encoded)")
        if abs(out_info["duration"] - offset / 1e6) > 2e-6:
            raise ValueError("Output end time differs from selected range")
        for field in ("width", "height", "rotation", "audio"):
            if info[field] != out_info[field]:
                raise ValueError(f"Output {field} differs from source")
        _run(["ffmpeg", "-v", "error", "-xerror", "-threads", "4", "-i", str(output),
              "-map", "0:v", "-map", "0:a?", "-f", "null", "-"])
        os.link(output, destination)
    return dict(segments=segments, frames=len(actual), duration=out_info["duration"],
                keyframes=len(output_keys), source_keyframes=len(keys))
