#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_SHA=$(git -C "$ROOT_DIR" rev-parse HEAD)
swift build --package-path "$ROOT_DIR" --configuration debug --arch arm64 --product DialDeckApp
BIN_DIR=$(swift build --package-path "$ROOT_DIR" --configuration debug --arch arm64 --show-bin-path)
APP_DIR="$ROOT_DIR/.build/DialDeck.app"
CONTENTS_DIR="$APP_DIR/Contents"

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS"
cp "$BIN_DIR/DialDeckApp" "$CONTENTS_DIR/MacOS/DialDeckApp"
cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>DialDeckApp</string>
    <key>CFBundleIdentifier</key>
    <string>com.dialdeck.app</string>
    <key>CFBundleName</key>
    <string>DialDeck</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>DialDeckBuildSHA</key>
    <string>$BUILD_SHA</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

printf 'Built DialDeck.app for commit %s\n' "$BUILD_SHA"
