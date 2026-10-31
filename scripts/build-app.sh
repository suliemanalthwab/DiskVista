#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="dist/DiskVista.app"
SPARKLE=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
test -d "$SPARKLE"
bash scripts/build-icon.sh
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN_DIR/DiskVista" "$APP/Contents/MacOS/DiskVista"
cp Sparkle-LICENSE.txt "$APP/Contents/Resources/Sparkle-LICENSE.txt"
cp Config/App.plist "$APP/Contents/Info.plist"
# ditto preserves framework symlinks and helper executable permissions.
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
touch "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" dist/DiskVista-macOS.zip
printf 'Built %s\n' "$APP"
