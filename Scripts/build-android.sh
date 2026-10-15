#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Supports either the isolated local toolchains or a conventional Android SDK/JDK.
if [ -n "${TV_INSTALLER_JAVA_HOME:-}" ]; then TASK_JAVA="$TV_INSTALLER_JAVA_HOME";
elif [ -d "$TASK_ROOT/.build/toolchains/jdk" ]; then TASK_JAVA="$(find "$TASK_ROOT/.build/toolchains/jdk" -type d -path '*/Contents/Home' -print -quit)";
else TASK_JAVA="$(/usr/libexec/java_home)"; fi
TASK_PLATFORM="${TV_INSTALLER_ANDROID_JAR:-$TASK_ROOT/.build/toolchains/android-files/android-36/android.jar}"
TASK_TOOLS="${TV_INSTALLER_ANDROID_TOOLS:-$TASK_ROOT/.build/toolchains/android-files/android-16}"
TASK_BUILD="$TASK_ROOT/.build/android"
mkdir -p "$TASK_BUILD/generated" "$TASK_BUILD/classes" "$TASK_BUILD/dex" "$TASK_ROOT/dist" "$TASK_ROOT/.signing"
export JAVA_HOME="$TASK_JAVA"
python3 - "$TASK_ROOT" <<'PY'
import pathlib,sys,xml.etree.ElementTree as ET
root=pathlib.Path(sys.argv[1])
ET.register_namespace('android','http://schemas.android.com/apk/res/android')
manifest=ET.parse(root/'Android/app/src/main/AndroidManifest.xml')
manifest.getroot().set('package','com.enderkidleaf.tvinstaller')
manifest.write(root/'.build/android/AndroidManifest.xml',encoding='utf-8',xml_declaration=True)
PY
"$TASK_TOOLS/aapt2" compile --dir "$TASK_ROOT/Android/app/src/main/res" -o "$TASK_BUILD/resources.zip"
"$TASK_TOOLS/aapt2" link -o "$TASK_BUILD/unsigned.apk" -I "$TASK_PLATFORM" \
    --manifest "$TASK_BUILD/AndroidManifest.xml" --java "$TASK_BUILD/generated" \
    --min-sdk-version 26 --target-sdk-version 36 --version-code 140 --version-name 1.4.0 \
    "$TASK_BUILD/resources.zip"
python3 - "$TASK_ROOT" <<'PY'
import pathlib,sys
root=pathlib.Path(sys.argv[1]); paths=list((root/'Android/app/src/main/java').rglob('*.java'))+list((root/'.build/android/generated').rglob('*.java'))
# javac argument files support quoted paths, including Chinese and spaces.
(root/'.build/android/sources.args').write_text('\n'.join('"'+str(p).replace('\\','\\\\').replace('"','\\"')+'"' for p in paths))
PY
"$TASK_JAVA/bin/javac" -encoding UTF-8 -source 8 -target 8 -Xlint:-options -bootclasspath "$TASK_PLATFORM:$TASK_TOOLS/core-lambda-stubs.jar" -d "$TASK_BUILD/classes" "@$TASK_BUILD/sources.args"
"$TASK_JAVA/bin/jar" --create --file "$TASK_BUILD/classes.jar" -C "$TASK_BUILD/classes" .
"$TASK_TOOLS/d8" --release --min-api 26 --lib "$TASK_PLATFORM" --output "$TASK_BUILD/dex" "$TASK_BUILD/classes.jar"
python3 - "$TASK_BUILD" <<'PY'
import pathlib,zipfile,sys
root=pathlib.Path(sys.argv[1])
with zipfile.ZipFile(root/'unsigned.apk','a',zipfile.ZIP_DEFLATED) as zip:
    for dex in sorted((root/'dex').glob('*.dex')):zip.write(dex,dex.name)
    zip.write(root.parent.parent/'Shared/PreparationGuide.json','assets/PreparationGuide.json')
PY
"$TASK_TOOLS/zipalign" -f -p 4 "$TASK_BUILD/unsigned.apk" "$TASK_BUILD/aligned.apk"
if [ ! -f "$TASK_ROOT/.signing/android-release.jks" ]; then
    umask 077
    openssl rand -hex 32 > "$TASK_ROOT/.signing/android-storepass"
    "$TASK_JAVA/bin/keytool" -genkeypair -keystore "$TASK_ROOT/.signing/android-release.jks" \
        -storepass:file "$TASK_ROOT/.signing/android-storepass" -keypass:file "$TASK_ROOT/.signing/android-storepass" -alias tv-installer -keyalg RSA -keysize 2048 \
        -validity 10000 -dname 'CN=Android LAN App Installer, OU=Local Build' -storetype JKS
fi
"$TASK_TOOLS/apksigner" sign --ks "$TASK_ROOT/.signing/android-release.jks" --ks-key-alias tv-installer \
    --ks-pass "file:$TASK_ROOT/.signing/android-storepass" \
    --out "$TASK_ROOT/dist/android-lan-app-installer-Android.apk" "$TASK_BUILD/aligned.apk"
"$TASK_TOOLS/apksigner" verify --verbose "$TASK_ROOT/dist/android-lan-app-installer-Android.apk"
printf 'Android package built\n'
