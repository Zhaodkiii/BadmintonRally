#!/bin/zsh
set -eu
cd "${0:A:h}/.."
bin="${RALLY_LAB_BINARY:-${TMPDIR:-/tmp}/RallyCourtMotionLab}"
xcrun swiftc -O Clients/iOS/Game/Rally.swift Clients/iOS/Art/ReturnMotion.swift Clients/iOS/Art/SpatialCourt.swift Tools/CourtMotionLab.swift -o "$bin"
exec "$bin" "$@"
