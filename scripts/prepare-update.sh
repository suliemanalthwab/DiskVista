#!/bin/bash
# Run locally: the signing private key stays in the macOS login Keychain.
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-app.sh
TOOLS=".build/artifacts/sparkle/Sparkle/bin"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Config/App.plist)"
PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Config/App.plist)"
ACTUAL_KEY="$("$TOOLS/generate_keys" --account org.diskvista.updates -p)"
if [ "$PUBLIC_KEY" != "$ACTUAL_KEY" ]; then
    printf 'Signing key does not match Config/App.plist. Refusing to publish.\n' >&2
    exit 1
fi
mkdir -p dist/update-archive
cp dist/DiskVista-macOS.zip dist/update-archive/DiskVista-macOS.zip
"$TOOLS/generate_appcast" --account org.diskvista.updates \
    --download-url-prefix "https://github.com/suliemanalthwab/DiskVista/releases/download/v${VERSION}/" \
    --maximum-deltas 0 --versions "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Config/App.plist)" \
    -o dist/appcast.xml dist/update-archive
"$TOOLS/sign_update" --account org.diskvista.updates --verify dist/appcast.xml
printf 'Prepared signed appcast: dist/appcast.xml\nPublish the release archive first; publish this feed last.\n'
