"""Compact local capture videos around swing events. Run with Python 3.10+ and ffmpeg/ffprobe.

Default keeps originals. --delete-originals permanently removes each source only
after validating its published reel and writing the original-to-reel time map.
Rerun the same command to resume. Close active capture sessions before running.
"""
import argparse
import csv
import fcntl
import hashlib
import json
import math
import os
import tempfile
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from swing_video import compact_video, probe
from swing_video_clock import map_windows
from swing_windows import windows


def write_json(path, data):
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as stream:
        json.dump(data, stream, ensure_ascii=False, indent=1, allow_nan=False)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(stream.name, path)


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(2**20), b""):
            h.update(block)
    return h.hexdigest()


def stamp(path):
    st = path.stat()
    return [st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns]


def intervals(rows):
    merged = []
    for r in sorted(rows, key=lambda r: r["start"]):
        if merged and r["start"] <= merged[-1][1] + .10:
            merged[-1][1] = max(merged[-1][1], r["end"])
        else:
            merged.append([r["start"], r["end"]])
    return merged


def process(root, out, source, events, delete):
    rel = source.relative_to(root)
    dst = out / rel.with_suffix(".mp4")
    dst.parent.mkdir(parents=True, exist_ok=True)
    sidecar = dst.with_suffix(".json")
    original = stamp(source)
    rows = map_windows(source, events)
    if not rows:
        return "无可对齐挥拍"
    entry = json.loads(sidecar.read_text()) if sidecar.exists() else {}
    if entry:
        if (original != entry["stamp"] or rows != entry["windows"]
                or not dst.is_file() or digest(dst) != entry["sha256"]):
            raise ValueError("已发布数据或输入发生变化，请核对后重新导出")
    else:
        meta = probe(source)
        duration = meta["duration"]
        cuts = intervals(rows)
        if not all(0 <= a < b <= duration + .05 for a, b in cuts):
            raise ValueError("帧表时间超出实际录像")
        cuts[-1][1] = min(cuts[-1][1], duration)
        with tempfile.TemporaryDirectory(dir=dst.parent) as workspace:
            candidate = Path(workspace) / dst.name
            media = compact_video(source, candidate, cuts)
            centers = []
            for row in rows:
                seg = next((s for s in media["segments"]
                            if s["source_start"] - .0001 <= row["center"] <= s["source_end"] + .0001), None)
                if seg is None:
                    raise ValueError("导出片段遗漏挥拍中心")
                t = seg["output_start"] + row["center"] - seg["source_start"]
                if not math.isfinite(t) or not -.001 <= t <= seg["output_end"] + .001:
                    raise ValueError("精简片内时间无效")
                centers.append(max(0, t))
            if candidate.stat().st_size >= original[2]:
                return "原片更小"
            if stamp(source) != original:
                raise ValueError("处理期间原片发生变化")
            entry = dict(original=str(rel), stamp=original, duration=duration,
                         size=candidate.stat().st_size, sha256=digest(candidate), windows=rows,
                         reel_centers=centers, media=media)
            if dst.exists() and digest(dst) != entry["sha256"]:
                raise ValueError(f"目标已有不同内容，保留原片及目标文件 {dst}")
            os.replace(candidate, dst)
        write_json(sidecar, entry)
    if delete:
        if stamp(source) != original:
            raise ValueError("删除前原片发生变化，已保留")
        source.unlink()
    return "已精简"


def session_jobs(root):
    for session in sorted(root.iterdir()):
        camera = session / "camera.mov"
        if camera.is_file():
            yield session, [camera]
    for session in sorted((root / "比赛实时诊断").glob("*")):
        movies = sorted((session / "视频").glob("*/*.mov"))
        if movies:
            yield session, movies


def write_index(root, out, skipped):
    stats = Counter()
    groups = set()
    target = out / "逐拍索引.tsv"
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8-sig", dir=out,
                                     newline="", delete=False) as stream:
        writer = csv.writer(stream, delimiter="\t")
        writer.writerow(["精简录像", "采集任务", "手机时刻秒", "原片挥拍秒", "精简片挥拍秒",
                         "精简片开始秒", "精简片结束秒", "证据"])
        for path in sorted(out.rglob("*.json")):
            if path.name == "处理报告.json":
                continue
            item = json.loads(path.read_text())
            video = path.with_suffix(".mp4").relative_to(out)
            stats.update(files=1, original_bytes=item["stamp"][2], compact_bytes=item["size"],
                         original_seconds=item["duration"], compact_seconds=item["media"]["duration"])
            if not (root / item["original"]).exists():
                stats["removed_files"] += 1
                stats["removed_bytes"] += item["stamp"][2]
            manifest = (root / item["original"]).parent / "manifest.json"
            prompt = json.loads(manifest.read_text()).get("prompt", "") if manifest.exists() else ""
            for row, t in zip(item["windows"], item["reel_centers"]):
                sid = video.parts[1] if video.parts[0] == "比赛实时诊断" else video.parts[0]
                groups.add((sid, row["phone_center"]))
                writer.writerow([video, prompt, row["phone_center"], round(row["center"], 4),
                                 round(t, 4), round(max(0, t + row["start"] - row["center"]), 4),
                                 round(min(item["media"]["duration"], t + row["end"] - row["center"]), 4),
                                 row["source"]])
    os.replace(stream.name, target)
    stats["distinct_centers"] = len(groups)
    remaining = [movie for _, movies in session_jobs(root) for movie in movies]
    stats["remaining_original_files"] = len(remaining)
    stats["remaining_original_bytes"] = sum(movie.stat().st_size for movie in remaining)
    stats["net_video_bytes_saved"] = stats["removed_bytes"] - stats["compact_bytes"]
    write_json(out / "处理报告.json", dict(totals=dict(stats), retained=skipped))
    print(json.dumps(stats, ensure_ascii=False), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", nargs="?", type=Path,
                        default=Path(__file__).resolve().parents[2] / "data/动作采集")
    parser.add_argument("--jobs", type=int, default=3)
    parser.add_argument("--delete-originals", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    if not root.is_dir() or args.jobs < 1:
        parser.error("采集目录或并发数无效")
    out = root / "挥拍精简"
    out.mkdir(exist_ok=True)
    with (out / ".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        skipped = {}

        def run(job):
            session, movies = job
            try:
                events = windows(session)
            except Exception as exc:
                return [(p, str(exc)) for p in movies]
            results = []
            for p in movies:
                try:
                    status = process(root, out, p, events, args.delete_originals)
                except Exception as exc:
                    status = f"处理失败 {exc}"
                results.append((p, status))
            return results
        with ThreadPoolExecutor(args.jobs) as pool:
            for result in pool.map(run, session_jobs(root)):
                for p, status in result:
                    print(status, p.relative_to(root), flush=True)
                    if status != "已精简":
                        skipped[str(p.relative_to(root))] = status
        write_index(root, out, skipped)


if __name__ == "__main__":
    main()
