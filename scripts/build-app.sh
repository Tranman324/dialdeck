#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
require_clean_worktree() {
    if [ -n "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=all)" ]; then
        echo "Refusing to stamp a build from a dirty worktree; commit or remove source changes first." >&2
        exit 1
    fi
}

require_tracked_source_inputs() {
    if find "$ROOT_DIR/Sources" -type l -print -quit | grep -q .; then
        echo "Refusing to build with symlinks in Sources; use tracked source files." >&2
        exit 1
    fi
    find "$ROOT_DIR/Sources" -type f -exec sh -c '
        root=$1
        shift
        for source do
            relative=${source#"$root"/}
            if ! git -C "$root" ls-files --error-unmatch -- "$relative" >/dev/null 2>&1; then
                echo "Refusing to build from an untracked source input: $relative" >&2
                exit 1
            fi
        done
    ' sh "$ROOT_DIR" {} +
}

require_clean_worktree
require_tracked_source_inputs
BUILD_SHA=$(git -C "$ROOT_DIR" rev-parse HEAD)
swift build --package-path "$ROOT_DIR" --configuration debug --arch arm64 --product DialDeckApp
BIN_DIR=$(swift build --package-path "$ROOT_DIR" --configuration debug --arch arm64 --show-bin-path)
require_clean_worktree
require_tracked_source_inputs
if [ "$(git -C "$ROOT_DIR" rev-parse HEAD)" != "$BUILD_SHA" ]; then
    echo "Refusing to stamp a build after HEAD changed during compilation." >&2
    exit 1
fi
APP_DIR="$ROOT_DIR/.build/DialDeck.app"
CONTENTS_DIR="$APP_DIR/Contents"

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS"
cp "$BIN_DIR/DialDeckApp" "$CONTENTS_DIR/MacOS/DialDeckApp"
EXECUTABLE_SHA256=$(shasum -a 256 "$CONTENTS_DIR/MacOS/DialDeckApp" | awk '{print $1}')
BUILD_EPOCH_NS=$(python3 -c 'import time; value = time.time_ns(); print(((value + 999) // 1000) * 1000)')
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
    <key>DialDeckExecutableSHA256</key>
    <string>$EXECUTABLE_SHA256</string>
    <key>DialDeckBuildEpochNS</key>
    <integer>$BUILD_EPOCH_NS</integer>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

printf 'Built DialDeck.app for commit %s\n' "$BUILD_SHA"
