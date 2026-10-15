#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_APP="$TASK_ROOT/dist/局域网安卓设备安装助手.app"
mkdir -p "$TASK_ROOT/.build" "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources"
if [ ! -x "$TASK_ROOT/Resources/adb" ]; then
    /usr/bin/curl --fail --location https://dl.google.com/android/repository/platform-tools-latest-darwin.zip -o "$TASK_ROOT/.build/platform-tools.zip"
    /usr/bin/unzip -q -o "$TASK_ROOT/.build/platform-tools.zip" -d "$TASK_ROOT/.build"
    cp "$TASK_ROOT/.build/platform-tools/adb" "$TASK_ROOT/Resources/adb"
    cp "$TASK_ROOT/.build/platform-tools/NOTICE.txt" "$TASK_ROOT/Resources/ADB-NOTICE.txt"
fi
TASK_SDK="$(xcrun --sdk macosx --show-sdk-path)"
bash "$TASK_ROOT/Scripts/prepare-build.sh"
TASK_FLAGS=(-vfsoverlay "$TASK_ROOT/.build/swift-overlay.json")
swiftc "${TASK_FLAGS[@]}" -module-cache-path "$TASK_ROOT/.build/module-cache" "$TASK_ROOT/Scripts/icon.swift" -o "$TASK_ROOT/.build/draw-icon"
"$TASK_ROOT/.build/draw-icon" "$TASK_ROOT/.build/AppIcon.iconset"
python3 "$TASK_ROOT/Scripts/pack-icon.py" "$TASK_ROOT/.build/AppIcon.iconset" "$TASK_ROOT/Resources/AppIcon.icns"
for TASK_ARCH in arm64 x86_64; do
    swiftc "${TASK_FLAGS[@]}" -swift-version 5 -O -sdk "$TASK_SDK" -target "$TASK_ARCH-apple-macosx13.0" \
        -module-cache-path "$TASK_ROOT/.build/module-cache" \
        "$TASK_ROOT/Sources/Core.swift" "$TASK_ROOT/Sources/PreparationGuide.swift" "$TASK_ROOT/Sources/DeviceTools.swift" "$TASK_ROOT/Sources/Troubleshooting.swift" "$TASK_ROOT/Sources/App.swift" \
        -o "$TASK_ROOT/.build/TVInstaller-$TASK_ARCH"
done
lipo -create "$TASK_ROOT/.build/TVInstaller-arm64" "$TASK_ROOT/.build/TVInstaller-x86_64" -output "$TASK_APP/Contents/MacOS/TVInstaller"
cp "$TASK_ROOT/Shared/PreparationGuide.json" "$TASK_APP/Contents/Resources/PreparationGuide.json"
cp "$TASK_ROOT/Resources/Info.plist" "$TASK_APP/Contents/Info.plist"
cp "$TASK_ROOT/Resources/adb" "$TASK_APP/Contents/Resources/adb"
cp "$TASK_ROOT/Resources/ADB-NOTICE.txt" "$TASK_APP/Contents/Resources/ADB-NOTICE.txt"
if [ -f "$TASK_ROOT/Resources/AppIcon.icns" ]; then cp "$TASK_ROOT/Resources/AppIcon.icns" "$TASK_APP/Contents/Resources/AppIcon.icns"; fi
chmod +x "$TASK_APP/Contents/Resources/adb" "$TASK_APP/Contents/MacOS/TVInstaller"
codesign --force --sign - "$TASK_APP/Contents/Resources/adb"
codesign --force --sign - "$TASK_APP"
ditto -c -k --sequesterRsrc --keepParent "$TASK_APP" "$TASK_ROOT/dist/android-lan-app-installer-macOS.zip"
printf 'Built: %s\n' "$TASK_APP"
