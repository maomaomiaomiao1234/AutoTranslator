#!/bin/sh
# Build a locally runnable, ad-hoc-signed macOS app.
# Usage: sh scripts/build-local.sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PROJECT_FILE="$PROJECT_DIR/AutoTranslator.xcodeproj"
SCHEME="AutoTranslator"
BUILD_DIR="${BUILD_DIR:-/private/tmp/AutoTranslatorDerivedData}"
DIST_DIR="$PROJECT_DIR/dist"
OUTPUT_APP="$DIST_DIR/AutoTranslator-local.app"
STAGING_APP="$DIST_DIR/.AutoTranslator-local.app.$$"

if [ -n "${DEVELOPER_DIR:-}" ]; then
    SELECTED_DEVELOPER_DIR="$DEVELOPER_DIR"
elif [ -x "/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild" ]; then
    SELECTED_DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
elif [ -x "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild" ]; then
    SELECTED_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
else
    echo "error: A full Xcode installation was not found." >&2
    echo "Set DEVELOPER_DIR to its Contents/Developer directory and try again." >&2
    exit 1
fi

XCODEBUILD="$SELECTED_DEVELOPER_DIR/usr/bin/xcodebuild"
BUILT_APP="$BUILD_DIR/Build/Products/Release/$SCHEME.app"

if [ ! -d "$SELECTED_DEVELOPER_DIR/Platforms/MacOSX.platform" ]; then
    echo "error: DEVELOPER_DIR must point to a full Xcode installation, not Command Line Tools." >&2
    exit 1
fi

if [ ! -d "$PROJECT_FILE" ]; then
    echo "error: Project file not found: $PROJECT_FILE" >&2
    exit 1
fi

cleanup() {
    [ -z "${STAGING_APP:-}" ] || [ ! -e "$STAGING_APP" ] || /bin/rm -rf "$STAGING_APP"
}
trap cleanup 0 HUP INT TERM

mkdir -p "$DIST_DIR"

echo "Building $SCHEME (Release) with $SELECTED_DEVELOPER_DIR..."
cd "$PROJECT_DIR"
DEVELOPER_DIR="$SELECTED_DEVELOPER_DIR" "$XCODEBUILD" build \
    -project "$PROJECT_FILE" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$BUILD_DIR" \
    CODE_SIGNING_ALLOWED=NO

if [ ! -d "$BUILT_APP" ]; then
    echo "error: Build completed but the app was not found: $BUILT_APP" >&2
    exit 1
fi

echo "Packaging $OUTPUT_APP..."
/usr/bin/ditto "$BUILT_APP" "$STAGING_APP"
/usr/bin/codesign --force --deep --sign - "$STAGING_APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGING_APP"

# Replace only the previous app produced by this script; source files are untouched.
/bin/rm -rf "$OUTPUT_APP"
/bin/mv "$STAGING_APP" "$OUTPUT_APP"
STAGING_APP=""

echo "Build complete: $OUTPUT_APP"
echo "Open it with: open \"$OUTPUT_APP\""
