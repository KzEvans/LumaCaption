#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FRAMEWORK_PARENT=${1:?FlutterMacOS framework parent required}
OUTPUT=${2:?output executable required}
mkdir -p "$ROOT/build/swift" "$(dirname "$OUTPUT")"
EXTRA=()
if [[ -f /Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap && -f /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap ]]; then
  : > "$ROOT/build/swift/empty.modulemap"
  python3 - "$ROOT/build/swift" <<'PY'
import json,sys
p=sys.argv[1]
json.dump({'version':0,'roots':[{'type':'file','name':'/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap','external-contents':p+'/empty.modulemap'}]},open(p+'/overlay.json','w'))
PY
  EXTRA=(-vfsoverlay "$ROOT/build/swift/overlay.json")
fi
swiftc -swift-version 5 -O -target arm64-apple-macos13.3 -sdk "$(xcrun --show-sdk-path)" \
  ${EXTRA[@]+"${EXTRA[@]}"} -F "$FRAMEWORK_PARENT" -framework FlutterMacOS -framework AppKit -framework AVFoundation -framework ScreenCaptureKit -framework Security -framework Carbon \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks "$ROOT"/native/macos/*.swift -o "$OUTPUT"
