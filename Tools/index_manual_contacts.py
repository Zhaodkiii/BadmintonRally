"""Print one CSV row per volume marker. Input is one or more phone-exported JSONL groups."""
import argparse
from array import array
from bisect import bisect_left
import csv
import json
from pathlib import Path
import sys


def index_group(path):
    times = array("d")
    marks = []
    header = None
    footer = None
    with path.open(encoding="utf-8") as stream:
        for number, line in enumerate(stream, 1):
            try:
                row = json.loads(line)
            except ValueError:
                if not line.endswith("\n"):
                    break  # A terminated process may leave one unfinished trailing record.
                raise ValueError(f"{path}:{number}: invalid JSON") from None
            kind = row["type"]
            if kind == "start":
                header = row
            elif kind == "imu":
                if times and row["t"] <= times[-1]:
                    raise ValueError(f"{path}:{number}: non-increasing IMU clock")
                times.append(row["t"])
            elif kind == "manualContact":
                marks.append(row)
            elif kind == "end":
                footer = row
    if not header or header.get("schema") != 1:
        raise ValueError(f"{path}: missing or unsupported session header")
    if footer and (footer["samples"] != len(times) or footer["markers"] != len(marks)):
        raise ValueError(f"{path}: footer counts disagree with records")
    for mark in marks:
        t = mark["t"]
        i = bisect_left(times, t)
        near = min(range(max(0, i-1), min(len(times), i+1)), key=lambda j: abs(times[j]-t), default=None)
        if not times or t < times[0] or t > times[-1]:
            quality = "outside_stream"
        elif i and times[i] != t and times[i] - times[i-1] > 0.05:
            quality = "imu_gap_over_50ms"
        else:
            quality = "covered"
        yield [path.stem, header["participant"], header["stroke"], header["speed"], header["leftHand"],
               mark["index"], mark["direction"], t, near if near is not None else "",
               round((times[near]-t)*1000, 3) if near is not None else "", quality,
               footer["reason"] if footer else "missing_footer", mark.get("source", ""),
               mark.get("referencePhoto", "")]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("groups", nargs="+", type=Path)
    writer = csv.writer(sys.stdout)
    writer.writerow(["group", "player", "task", "speed", "left_hand", "marker_index", "volume_direction",
                     "marked_uptime_s", "nearest_imu_index_0based", "imu_minus_mark_ms", "coverage", "end_reason",
                     "marker_source", "reference_photo"])
    for group in parser.parse_args().groups:
        writer.writerows(index_group(group))
