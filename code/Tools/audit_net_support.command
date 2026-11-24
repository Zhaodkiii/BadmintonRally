#!/bin/zsh
set -eu
cd "${0:A:h}/.."
output="${1:?usage: audit_net_support.command /absolute/path/to/output.csv [source snapshot directory]}"
src="${2:-}"
build="$(mktemp -d -t badminton-net-support)"
trap 'rm -rf "$build"' EXIT
if [[ -z "$src" ]]; then
  cp Tools/CourtMotionLab.swift Clients/iOS/Game/Rally.swift Clients/iOS/Art/{ReturnMotion,SpatialCourt}.swift "$build/"
else
  cp "$src"/{CourtMotionLab,Rally,ReturnMotion,SpatialCourt}.swift "$build/"
fi
# Keep private test inputs and the production runner in one compilation unit.
sed 's/^@main enum CourtMotionLab/enum CourtMotionLab/' "$build/CourtMotionLab.swift" > "$build/Audit.swift"
cat Tools/NetSupportAudit.swift >> "$build/Audit.swift"
xcrun swiftc -O "$build"/{Rally,ReturnMotion,SpatialCourt,Audit}.swift -o "$build/audit"
"$build/audit" "$output"
