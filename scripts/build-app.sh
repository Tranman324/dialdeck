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
BUILD_ID=$(python3 -c 'import uuid; print(uuid.uuid4().hex)')
BUILD_ROOT="$ROOT_DIR/.build/candidates/$BUILD_SHA/$BUILD_ID"
SOURCE_SNAPSHOT="$ROOT_DIR/.build/source-snapshots/$BUILD_SHA/$BUILD_ID"
SWIFT_BUILD_DIR="$ROOT_DIR/.build/swift-builds/$BUILD_SHA/$BUILD_ID"
APP_DIR="$BUILD_ROOT/DialDeck.app"
APP_STAGING_DIR="$BUILD_ROOT/.DialDeck.app.tmp"

if [ -e "$BUILD_ROOT" ] || [ -e "$SOURCE_SNAPSHOT" ] || [ -e "$SWIFT_BUILD_DIR" ]; then
    echo "Refusing to reuse an existing build identity: $BUILD_ID" >&2
    exit 1
fi
mkdir -p "$(dirname "$BUILD_ROOT")"
mkdir -p "$SOURCE_SNAPSHOT" "$SWIFT_BUILD_DIR"
ARCHIVE_PATH="$BUILD_ROOT-source.tar"
if ! git -C "$ROOT_DIR" archive --format=tar -o "$ARCHIVE_PATH" "$BUILD_SHA"; then
    echo "Could not create the committed source snapshot for $BUILD_SHA." >&2
    exit 1
fi
if ! tar -xf "$ARCHIVE_PATH" -C "$SOURCE_SNAPSHOT"; then
    echo "Could not extract the committed source snapshot for $BUILD_SHA." >&2
    exit 1
fi
rm -f "$ARCHIVE_PATH"

swift build --package-path "$SOURCE_SNAPSHOT" --scratch-path "$SWIFT_BUILD_DIR" --configuration debug --arch arm64 --product DialDeckApp
BIN_DIR=$(swift build --package-path "$SOURCE_SNAPSHOT" --scratch-path "$SWIFT_BUILD_DIR" --configuration debug --arch arm64 --show-bin-path)
require_clean_worktree
require_tracked_source_inputs
if [ "$(git -C "$ROOT_DIR" rev-parse HEAD)" != "$BUILD_SHA" ]; then
    echo "Refusing to stamp a build after HEAD changed during compilation." >&2
    exit 1
fi
if [ -e "$APP_DIR" ]; then
    echo "Refusing to replace an existing candidate bundle: $APP_DIR" >&2
    exit 1
fi
CONTENTS_DIR="$APP_STAGING_DIR/Contents"
mkdir -p "$CONTENTS_DIR/MacOS"
cp "$BIN_DIR/DialDeckApp" "$CONTENTS_DIR/MacOS/DialDeckApp"
EXECUTABLE_SHA256=$(shasum -a 256 "$CONTENTS_DIR/MacOS/DialDeckApp" | awk '{print $1}')
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
    <key>DialDeckBuildID</key>
    <string>$BUILD_ID</string>
    <key>DialDeckExecutableSHA256</key>
    <string>$EXECUTABLE_SHA256</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST
mv "$APP_STAGING_DIR" "$APP_DIR"
rm -rf "$SOURCE_SNAPSHOT"

printf 'Built DialDeck.app for commit %s, build %s\n' "$BUILD_SHA" "$BUILD_ID"
printf 'Bundle: %s\n' "$APP_DIR"
