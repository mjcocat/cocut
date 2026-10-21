#!/bin/bash
# PlayerChain (which keeps the phone frame on the spotlighted player). Plain Swift: macOS or Linux.
# With no arguments: synthetic checks. With arguments, runs on people found in a real clip:
#   detections.json out.json time x y [body|head] [number]
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)
if [ $# -eq 0 ]; then
  swiftc -O Shared/Export/PlayerChain.swift Tests/PlayerChainChecks/main.swift -o "$out/checks"
  "$out/checks"
else
  swiftc -O Shared/Export/PlayerChain.swift Shared/Export/CameraPlanner.swift Tests/PlayerChain/main.swift -o "$out/test-player-chain"
  "$out/test-player-chain" "$@"
fi
