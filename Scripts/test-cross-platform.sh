#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -n "${TV_INSTALLER_JAVA_HOME:-}" ]; then TASK_JAVA="$TV_INSTALLER_JAVA_HOME";
else TASK_JAVA="$(find "$TASK_ROOT/.build/toolchains/jdk" -type d -path '*/Contents/Home' -print -quit)"; fi
if [ -x "$TASK_ROOT/.build/toolchains/dotnet/dotnet" ]; then TASK_DOTNET="$TASK_ROOT/.build/toolchains/dotnet/dotnet"; else TASK_DOTNET="$(command -v dotnet)"; fi
mkdir -p "$TASK_ROOT/.build/java-tests"
"$TASK_JAVA/bin/javac" -encoding UTF-8 -d "$TASK_ROOT/.build/java-tests" \
    "$TASK_ROOT/Android/app/src/main/java/com/enderkidleaf/tvinstaller/AdbCore.java" \
    "$TASK_ROOT/Android/app/src/main/java/com/enderkidleaf/tvinstaller/DeviceCommands.java" \
    "$TASK_ROOT/Android/app/src/main/java/com/enderkidleaf/tvinstaller/TroubleshootingCore.java" \
    "$TASK_ROOT/CrossPlatformTests/AndroidTroubleshootingTests.java" "$TASK_ROOT/CrossPlatformTests/AndroidCoreTests.java" "$TASK_ROOT/CrossPlatformTests/AndroidTvSmoke.java"
"$TASK_JAVA/bin/java" -cp "$TASK_ROOT/.build/java-tests" com.enderkidleaf.tvinstaller.AndroidCoreTests
export DOTNET_CLI_HOME="$TASK_ROOT/.build/dotnet-home"
export NUGET_PACKAGES="$TASK_ROOT/.build/nuget"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_GENERATE_ASPNET_CERTIFICATE=false
"$TASK_DOTNET" run --project "$TASK_ROOT/CrossPlatformTests/WindowsCoreTests.csproj" -c Release
