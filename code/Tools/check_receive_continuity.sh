#!/bin/sh
set -eu
code_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
run_dir=$(mktemp -d "${TMPDIR:-/tmp}/rally-receive.XXXXXX")
trap 'rm -rf "$run_dir"' EXIT
ios="$code_dir/Clients/iOS"
cp "$ios"/Resources/*.json "$run_dir/"
xcrun swiftc -D DEBUG -D P006_OFFLINE \
  "$ios/Game/Rally.swift" "$ios/Art/ReturnMotion.swift" "$ios/Art/SpatialCourt.swift" \
  "$ios/Motion/ButtonSwing.swift" "$ios/Motion/SwingCurveModel.swift" \
  "$ios/App/SimulatorSinglesInput.swift" "$code_dir/Tests/Checks/ReceiveContinuity.swift" \
  -o "$run_dir/check"
"$run_dir/check" "$run_dir/match.tsv"
