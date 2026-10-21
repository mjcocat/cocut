#!/bin/bash
# Tests PlayerFollower (the logic that keeps the phone frame on the spotlighted player) with
# synthetic clips. Plain Swift: runs on macOS or Linux.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)
swiftc -O Shared/Export/PlayerFollower.swift Tests/PlayerFollower/main.swift -o "$out/test-player-follower"
"$out/test-player-follower"
