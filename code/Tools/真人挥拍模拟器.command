#!/bin/bash
set -euo pipefail

case "${1:-single}" in
  single|match|baseline) mode=${1:-single} ;;
  -h|--help)
    echo '用法：真人挥拍模拟器.command [single|match|baseline] [回放 JSON]'
    echo 'single 重放真人单球，match 用增强模型打整局，baseline 用原模型打整局。'
    exit 0 ;;
  *) echo '可选模式为 single、match、baseline。' >&2; exit 2 ;;
esac

root=$(cd "$(dirname "$0")/../.." && pwd)
device=89B4EB3F-3B23-4F9F-AA91-5D3AC77016A8
library=${2:-"$root/code/Clients/iOS/Resources/RawSwingReplay.json"}
build_dir="${TMPDIR:-/tmp}/BadmintonRawSwingBuild"
archive="$root/data/正式对局验收/P038"
mkdir -p "$archive"
test -s "$library"
xcrun simctl bootstatus "$device" -b
xcodebuild build-for-testing -project "$root/code/BadmintonRally.xcodeproj" -scheme BadmintonRally \
  -destination "platform=iOS Simulator,id=$device" -derivedDataPath "$build_dir" -configuration Debug
products="$build_dir/Build/Products"
xcrun simctl install "$device" "$products/Debug-iphonesimulator/BadmintonRally.app"
runs=("$products"/BadmintonRally_iphonesimulator*-arm64.xctestrun)
test -f "${runs[0]}"
output="$archive/复跑-$(date +%Y%m%d-%H%M%S)-$mode"
bash "$root/docs/项目制作/岗位/10-动画QA/任务/P038-正式比赛复现证据/record_raw_match.sh" \
  "$output" "${runs[0]}" "$mode" "$library"
echo "录像与逐球记录已保存到 $output"
