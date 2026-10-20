#!/usr/bin/env bash
# Checks the phone-export camera planner (plain Swift, no Apple frameworks): runs on a Mac or on
# Linux with a Swift toolchain. Usage: scripts/test-camera-planner.sh
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O Shared/Export/CameraPlanner.swift Tests/CameraPlanner/main.swift -o "$out/planner-test"
"$out/planner-test"
