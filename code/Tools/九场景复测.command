#!/bin/zsh
set -eu
cd "${0:A:h}/.."
root="${1:-$PWD/../data/羽球比赛训练/九场景逐轮验证}"
index="${2:-$PWD/../data/羽毛球比赛视频/接球动作片段精选/片段索引.json}"
mkdir -p "$root"
if [[ -n "${3:-}" ]]; then
  round="$root/$3"
  mkdir -p "$round"
  [[ ! -e "$round/回放.csv" ]] || { echo "此轮已存在" >&2; exit 1; }
else
  round="$(mktemp -d "$root/$(date +%Y%m%d-%H%M%S)-XXXX")"
fi
build="$(mktemp -d "${TMPDIR:-/tmp}/RallyCourtMotionLab.XXXXXX")"
trap 'rm -f "$build/lab"; rmdir "$build"' EXIT
lab="$build/lab"
RALLY_LAB_BINARY="$lab" Tools/动作回放.command --nine "$round"
"$lab" --rear-timing "$round/后场按键时机.csv"
"$lab" --recovery "$round/收拍.csv"
"$lab" --legs "$round/腿长.csv"
"$lab" --phases "$round/连续画面"
encoder="$(command -v ffmpeg || .venv/bin/python -c 'import imageio_ffmpeg;print(imageio_ffmpeg.get_ffmpeg_exe())')"
"$lab" --films "$round/实速" "$encoder"
for dir in "$round"/连续画面/*(/); do
  "$encoder" -nostdin -hide_banner -loglevel error -framerate 20 -i "$dir/%03d.jpg" -an -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$dir.mp4"
done
python3 Tools/report_court_round.py "$round" "$index"
echo "$round/测试报告.md"
