"""Record one ordinary singles match on the project's designated simulator."""
import argparse
import csv
import hashlib
import json
import shutil
import signal
import subprocess
import time
from pathlib import Path

DEVICE = "89B4EB3F-3B23-4F9F-AA91-5D3AC77016A8"
BUNDLE = "com.daokaihua.badmintonrally"


def sim(*args, timeout=45):
    return subprocess.check_output(
        ["xcrun", "simctl", *args], text=True, timeout=timeout
    ).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="BadmintonRally.app built for the simulator (Debug)")
    parser.add_argument("directory", type=Path, help="new directory for this run")
    args = parser.parse_args()
    binary = args.app / "BadmintonRally"
    images = [binary, *sorted(args.app.glob("*.debug.dylib"))]
    fingerprints = {item.name: hashlib.sha256(item.read_bytes()).hexdigest() for item in images}
    args.directory.mkdir(parents=True, exist_ok=False)
    sim("bootstatus", DEVICE, "-b", timeout=120)
    sim("install", DEVICE, str(args.app.resolve()), timeout=600)
    container = Path(sim("get_app_container", DEVICE, BUNDLE, "data"))
    journal = container / "Documents/P006-单打.tsv"
    video = args.directory / "正式单打.mp4"
    with ((args.directory / "录屏日志.txt").open("w") as log,
          (args.directory / "录像时钟.tsv").open("w", buffering=1) as timeline):
        timeline.write("wall_ns\tvideo_elapsed_s\tevents\tgame_s\n")
        video_start = time.monotonic()
        recorder = subprocess.Popen(
            ["xcrun", "simctl", "io", DEVICE, "recordVideo", "--codec=h264", str(video)],
            stdout=log, stderr=log,
        )
        try:
            time.sleep(1)
            started = time.time_ns()
            try:
                sim("launch", "--terminate-running-process", DEVICE, BUNDLE, "-p006Singles", timeout=120)
            except subprocess.CalledProcessError:
                # SpringBoard can reject pre-termination after a simulator cold boot.
                sim("launch", DEVICE, BUNDLE, "-p006Singles", timeout=120)
            deadline = time.monotonic() + 1200
            last_count = 0
            while time.monotonic() < deadline:
                if recorder.poll() is not None:
                    raise RuntimeError("录屏提前结束")
                if journal.exists() and journal.stat().st_mtime_ns >= started:
                    with journal.open() as stream:
                        rows = list(csv.DictReader(stream, delimiter="\t"))
                    if len(rows) > last_count:
                        last_count = len(rows)
                        elapsed = time.monotonic() - video_start
                        timeline.write(f"{time.time_ns()}\t{elapsed:.3f}\t{last_count}\t{rows[-1]['gameSeconds']}\n")
                    if rows and rows[-1]["event"] == "finished":
                        break
                time.sleep(1)
            else:
                raise TimeoutError("未收到本局结算记录")
            # On a loaded simulator the displayed frame may trail the result event.
            time.sleep(25)
        finally:
            if recorder.poll() is None:
                recorder.send_signal(signal.SIGINT)
                try:
                    recorder.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    recorder.kill()
                    recorder.wait()
                    raise RuntimeError("录屏封装超时")
    probe = subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0",
        "-count_frames", "-show_entries", "stream=nb_read_frames,duration,width,height",
        "-of", "json", str(video)], text=True)
    points = [row for row in rows if row["event"] == "point"]
    if rows[0]["event"] != "home" or not points or len(points) != int(rows[-1]["point"]):
        raise ValueError("比赛事件不完整")
    stream = json.loads(probe)["streams"][0]
    if int(stream["nb_read_frames"]) < 1:
        raise ValueError("录像没有可解码画面")
    shutil.copy2(journal, args.directory / journal.name)
    result = dict(device=DEVICE, images_sha256=fingerprints, input="DEBUG simulated presses",
                  score=[rows[-1]["near"], rows[-1]["far"]], video=stream)
    (args.directory / "场次.json").write_text(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
