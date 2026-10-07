#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
VAD_MODEL=$(python3 "$ROOT/scripts/prepare_vad_model.py")
FLUTTER=${LUMA_FLUTTER:-"$ROOT/.tools/flutter/bin/flutter"}
if [[ ! -x "$FLUTTER" ]]; then FLUTTER=$(command -v flutter); fi
"$FLUTTER" pub get --enforce-lockfile
"$FLUTTER" precache --macos
"$FLUTTER" assemble --output=build/flutter-macos -dTargetPlatform=darwin -dBuildMode=release -dDarwinArchs=arm64 release_macos_bundle_flutter_assets
WHISPER_ARGS=()
if [[ -f "$ROOT/.tools/whisper.cpp/CMakeLists.txt" ]]; then WHISPER_ARGS=(-DWHISPER_SOURCE="$ROOT/.tools/whisper.cpp"); fi
cmake -S native/whisper -B build/whisper -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=13.3 -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON ${WHISPER_ARGS[@]+"${WHISPER_ARGS[@]}"}
cmake --build build/whisper --config Release -j 6
SDK_ROOT=$(cd "$(dirname "$FLUTTER")/.." && pwd)
FRAMEWORK_PARENT="$SDK_ROOT/bin/cache/artifacts/engine/darwin-x64-release/FlutterMacOS.xcframework/macos-arm64_x86_64"
# Stage outside synced Documents: File Provider can recreate Finder metadata
# between xattr cleanup and signing, making codesign reject the generated app.
STAGING=$(mktemp -d /private/tmp/lumacaption-package.XXXXXX)
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/dmg/LumaCaption.app"
mkdir -p "$APP/Contents/"{MacOS,Frameworks,Resources}
ditto "$FRAMEWORK_PARENT/FlutterMacOS.framework" "$APP/Contents/Frameworks/FlutterMacOS.framework"
# This deliverable is arm64 only; do not imply an untested Universal build.
ENGINE="$APP/Contents/Frameworks/FlutterMacOS.framework/Versions/A/FlutterMacOS"
lipo "$ENGINE" -thin arm64 -output "$ENGINE.arm64"
mv "$ENGINE.arm64" "$ENGINE"
ditto build/flutter-macos/App.framework "$APP/Contents/Frameworks/App.framework"
cp build/whisper/liblumawhisper.dylib "$APP/Contents/Frameworks/"
native/macos/build-swift.sh "$FRAMEWORK_PARENT" "$APP/Contents/MacOS/LumaCaption"
cp native/macos/Info.plist "$APP/Contents/Info.plist"
cp assets/branding/LumaCaption.icns "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/vad"
cp "$VAD_MODEL" "$APP/Contents/Resources/vad/ggml-silero-v5.1.2.bin"
cp assets/vad-model.json "$APP/Contents/Resources/vad/manifest.json"
ditto docs/licenses "$APP/Contents/Resources/licenses"
cp docs/THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"
xattr -cr "$APP"
IDENTITY=${LUMA_SIGN_IDENTITY:--}
codesign --force --sign "$IDENTITY" "$APP/Contents/Frameworks/FlutterMacOS.framework"
codesign --force --sign "$IDENTITY" "$APP/Contents/Frameworks/App.framework"
codesign --force --sign "$IDENTITY" "$APP/Contents/Frameworks/liblumawhisper.dylib"
SIGN_OPTIONS=()
if [[ "$IDENTITY" != "-" ]]; then SIGN_OPTIONS=(--options runtime); fi
codesign --force --sign "$IDENTITY" ${SIGN_OPTIONS[@]+"${SIGN_OPTIONS[@]}"} --entitlements native/macos/Release.entitlements "$APP"
codesign --verify --deep --strict "$APP"
OUTPUT_DIRECTORY=${LUMA_OUTPUT_DIRECTORY:-"$ROOT/dist"}
mkdir -p "$OUTPUT_DIRECTORY"
OUTPUT_DIRECTORY=$(cd "$OUTPUT_DIRECTORY" && pwd)
ditto --noextattr --norsrc "$APP" "$OUTPUT_DIRECTORY/LumaCaption.app"
ln -s /Applications "$STAGING/dmg/Applications"
DMG="$OUTPUT_DIRECTORY/LumaCaption-0.1.0-macos-arm64-liquid-glass.dmg"
rm -f "$DMG"
hdiutil create -volname LumaCaption -srcfolder "$STAGING/dmg" -ov -format UDZO "$DMG"
(cd "$OUTPUT_DIRECTORY" && shasum -a 256 "$(basename "$DMG")") > "$DMG.sha256"
"$SDK_ROOT/bin/dart" run scripts/artifact_manifest.dart "$DMG" macos arm64 "$APP"
