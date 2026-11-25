"""Find swing windows on the phone monotonic clock (all times in seconds)."""
import csv
import json
import math
from pathlib import Path


def window(center, source, start=None, end=None):
    if not math.isfinite(center):
        raise ValueError("non-finite event time")
    return dict(start=center - .55 if start is None else start, center=center,
                end=center + .40 if end is None else end, source=source)


def rotation_windows(samples, source, minimum_peak):
    """Keep sustained bursts, separating movements across quiet periods or gaps."""
    result = []
    first = last = previous = None
    count = 0
    peak = 0.

    def finish():
        if count >= 3 and last - first >= .02 and peak >= minimum_peak:
            result.append(window(peak_time, source, first - .30, last + .32))

    for t, rate in samples:
        if not math.isfinite(rate) or not math.isfinite(t):
            raise ValueError("invalid IMU sample")
        if previous is not None and t <= previous:
            raise ValueError("non-increasing IMU time")
        if count and (t - last > .18 or t - previous > .08):
            finish()
            count = 0
            peak = 0.
        previous = t
        if rate < minimum_peak * .45:
            continue
        if not count:
            first = t
        count += 1
        last = t
        if rate > peak:
            peak, peak_time = rate, t
    finish()
    return result


def training_windows(session):
    from swing_video_clock import clock_fit

    manifest = json.loads((session / "manifest.json").read_text())
    action_path = session / "action_window.json"
    if not action_path.exists() or manifest["state"] != "complete":
        return []
    action = json.loads(action_path.read_text())
    if action["session_id"].lower() != session.name.lower():
        raise ValueError("action window belongs to another session")
    slope, offset = clock_fit(session / "clocks.jsonl")
    begin = (action["mac_begin"] - offset) / slope
    end = (action["mac_end"] - offset) / slope
    with (session / "samples.csv").open(encoding="utf-8-sig") as stream:
        samples = ((float(r["t_phone"]), math.hypot(*(float(r[k]) for k in ("rx", "ry", "rz"))))
                   for r in csv.DictReader(stream))
        return rotation_windows(((t, speed) for t, speed in samples if begin <= t <= end),
                                "prompt_imu_peak", 1.5)


def match_windows(session):
    marks = []
    priority = {"manualContact": 0, "impact": 1, "judgment": 2,
                "candidate": 3, "swingPreview": 4}

    def samples():
        # Read primary records so a missing or stale flat export loses no markers.
        for path in sorted((session / "batches").glob("*.json"), key=lambda p: int(p.stem)):
            batch = json.loads(path.read_bytes())
            if batch["match"].lower() != session.name.lower() or batch["sequence"] != int(path.stem):
                raise ValueError(f"mismatched batch: {path}")
            for event in batch["events"]:
                kind = event["kind"]
                if kind not in priority:
                    continue
                if kind == "candidate" and not event["text"].startswith("检测到挥拍"):
                    continue
                t = event.get("peakTime") or event["time"]
                marks.append((priority[kind], window(t, kind)))
            for frame in batch["frames"]:
                yield frame["t"], math.hypot(*frame["v"][:3])

    bursts = rotation_windows(samples(), "imu_peak_unconfirmed", 4.)
    result = []
    for _, mark in sorted(marks, key=lambda pair: (pair[0], pair[1]["center"])):
        # Keep every distinct button press, including misses. Later diagnostics
        # within the same movement can describe a slightly different peak.
        tolerance = 0 if mark["source"] == "manualContact" else .28
        if not any(abs(other["center"] - mark["center"]) <= tolerance for other in result):
            result.append(mark)
    for burst in bursts:
        near = [r for r in result if burst["start"] <= r["center"] <= burst["end"]]
        if near:
            closest = min(near, key=lambda r: abs(r["center"] - burst["center"]))
            closest["start"] = min(closest["start"], burst["start"])
            closest["end"] = max(closest["end"], burst["end"])
        else:
            result.append(burst)
    return sorted(result, key=lambda r: r["center"])


def windows(session: Path) -> list[dict]:
    """Return start/center/end in phone uptime; map separately for each recording."""
    if (session / "manifest.json").is_file():
        return training_windows(session)
    return match_windows(session)
