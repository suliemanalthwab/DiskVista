#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="dist/DiskVista.app"
./scripts/build-icon.sh
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN_DIR/DiskVista" "$APP/Contents/MacOS/DiskVista"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DiskVista</string>
<key>CFBundleIdentifier</key><string>org.diskvista.app</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundleName</key><string>DiskVista</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.1</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
touch "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" dist/DiskVista-macOS.zip
printf 'Built %s\n' "$APP"
