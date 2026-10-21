#!/bin/bash
# Cocut Lab's scoring and tuning (plain Swift: macOS or Linux) on a lab folder:
#   scripts/test-lab-core.sh <lab folder> [tries]
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)
swiftc -O Shared/Export/PlayerChain.swift Shared/Export/CameraPlanner.swift Lab/Core/LabStore.swift Lab/Core/LabTuner.swift \
  Tests/LabCore/main.swift -o "$out/test-lab-core"
"$out/test-lab-core" "$@"
