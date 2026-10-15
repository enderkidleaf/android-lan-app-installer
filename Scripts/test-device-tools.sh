#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bash "$TASK_ROOT/Scripts/prepare-build.sh"
swiftc -D QUEUE_TESTING -vfsoverlay "$TASK_ROOT/.build/swift-overlay.json" -swift-version 5 \
    -module-cache-path "$TASK_ROOT/.build/module-cache" \
    "$TASK_ROOT/Sources/Core.swift" "$TASK_ROOT/Sources/PreparationGuide.swift" "$TASK_ROOT/Sources/DeviceTools.swift" "$TASK_ROOT/Sources/Troubleshooting.swift" "$TASK_ROOT/Sources/App.swift" \
    "$TASK_ROOT/Tests/DeviceToolsTests.swift" -o "$TASK_ROOT/.build/device-tools-tests"
"$TASK_ROOT/.build/device-tools-tests"
