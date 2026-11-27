#!/bin/bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: record_raw_match.sh NEW_OUTPUT_DIRECTORY FROZEN_XCTESTRUN single|single-trained|match|baseline|recorded-return|cued-return|raw-timing-match REPLAY_JSON" >&2
  exit 2
fi

output="$1"
xctestrun="$2"
replay_file=P038-replay.json
case "${3:-match}" in
  match) method=testRawSwingFullMatch ;;
  baseline) method=testRawSwingBaselineMatch ;;
  single) method=testRawSwingOneBall ;;
  single-trained) method=testRawSwingTrainedOneBall ;;
  recorded-return) method=testRecordedReturnTiming; replay_file=P039-replay.json ;;
  cued-return) method=testCuedReturnTiming; replay_file=P039-replay.json ;;
  raw-timing-match) method=testRecordedTimingFullMatch; replay_file=P040-replay.json ;;
  *) echo 'Unknown match mode' >&2; exit 2 ;;
esac

device=89B4EB3F-3B23-4F9F-AA91-5D3AC77016A8
app_id=cn.zhaodk.badmintonrally
suite="ClubFlowTests/FormalMatchAuditTests/$method"
test -f "$xctestrun"
test -s "$4"
mkdir "$output"
xcodebuild -version > "$output/toolchain.txt"
xcrun simctl list devices --json > "$output/devices.json"
shasum -a 256 "$xctestrun" > "$output/xctestrun.sha256"
python3 - "$output/devices.json" "$device" <<'PY'
import json
import sys
d = json.load(open(sys.argv[1]))["devices"]
if not any(b["udid"] == sys.argv[2] and b["state"] == "Booted"
           for b in d.get("com.apple.CoreSimulator.SimRuntime.iOS-27-2", [])):
    raise SystemExit("The required iOS 27.2 simulator is not booted")
PY

container=$(xcrun simctl get_app_container "$device" "$app_id" data)
mkdir -p "$container/Documents"
cp "$4" "$output/$replay_file"
cp "$4" "$container/Documents/$replay_file"
touch "$output/test-start"
xcrun simctl io "$device" recordVideo --codec=h264 "$output/full.mp4" 2>"$output/recording.log" &
recorder=$!
stop_recording() {
  if kill -0 "$recorder" 2>/dev/null; then
    kill -INT "$recorder"
    wait "$recorder" || true
  fi
}
trap stop_recording EXIT
for ((i=0; i<100; i++)); do
  if rg -q 'Recording started' "$output/recording.log"; then break; fi
  if ! kill -0 "$recorder" 2>/dev/null; then cat "$output/recording.log" >&2; exit 1; fi
  sleep .1
done
rg -q 'Recording started' "$output/recording.log"
python3 -c 'import time; print(time.time())' > "$output/recording-start-wall-approx.txt"

status=0
xcodebuild test-without-building -xctestrun "$xctestrun" \
  -destination "platform=iOS Simulator,id=$device" -parallel-testing-enabled NO \
  -only-testing:"$suite" -resultBundlePath "$output/result.xcresult" \
  > "$output/xcui.log" 2>&1 || status=$?
stop_recording
trap - EXIT

container=$(xcrun simctl get_app_container "$device" "$app_id" data)
for name in P035-events.tsv P035-frames.jsonl; do
  if [[ -s "$container/Documents/$name" && "$container/Documents/$name" -nt "$output/test-start" ]]; then
    cp "$container/Documents/$name" "$output/"
  else
    echo "Missing $name" >&2
    status=1
  fi
done
for trace in "$container"/Documents/P038-*; do
  if [[ -f "$trace" && "$trace" -nt "$output/test-start" ]]; then cp "$trace" "$output/"; fi
done
bundle=$(xcrun simctl get_app_container "$device" "$app_id" app)
shasum -a 256 "$bundle/BadmintonRally" "$bundle/"*.dylib \
  "$bundle/"*.json "$bundle/"LinCheng*.usdz "$bundle/"LinCheng*.brmesh > "$output/installed.sha256"
ffmpeg -nostdin -v error -xerror -i "$output/full.mp4" -map 0:v:0 -fps_mode passthrough -enc_time_base 1:1000000 -f null -
ffprobe -v error -count_frames -select_streams v:0 \
  -show_entries stream=width,height,duration,nb_read_frames -of json "$output/full.mp4" > "$output/video.json"
if [[ -d "$output/result.xcresult" ]]; then
  xcrun xcresulttool get test-results summary --path "$output/result.xcresult" --format json > "$output/summary.json"
  xcrun xcresulttool export attachments --path "$output/result.xcresult" --output-path "$output/attachments" > "$output/attachments.log"
fi
exit "$status"
