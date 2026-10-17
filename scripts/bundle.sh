#!/usr/bin/env bash
# Builds a universal (arm64 + x86_64) release DevTidy.app (menu bar app, LSUIElement) into build/DevTidy.app.
# Each architecture is built separately and the two executables are joined with `lipo -create`.
#
# Env knobs:
#   VERSION    CFBundleShortVersionString      (default 0.1.0)
#   BUILD      CFBundleVersion                 (default date +%Y%m%d%H%M)
#   BUNDLE_ID  CFBundleIdentifier              (default dev.minata.DevTidy)
#   SIGN       adhoc (default) | none | <codesign identity>
#              An identity signs with the hardened runtime and a secure timestamp (Developer ID / notarization ready).
#   DEVELOPER_DIR                              (default /Applications/Xcode.app/Contents/Developer when present)
#
# Works from a clean checkout; runs from the repository root regardless of the caller's cwd.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [[ -d "$DEVELOPER_DIR" ]]; then
    export DEVELOPER_DIR
else
    unset DEVELOPER_DIR
fi

VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-$(date +%Y%m%d%H%M)}"
BUNDLE_ID="${BUNDLE_ID:-dev.minata.DevTidy}"
SIGN="${SIGN:-adhoc}"

# The values are substituted into a plist with sed: keep them to a safe alphabet.
for pair in "VERSION=$VERSION" "BUILD=$BUILD" "BUNDLE_ID=$BUNDLE_ID"; do
    value="${pair#*=}"
    if [[ ! "$value" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "bundle.sh: ${pair%%=*} contains characters outside [A-Za-z0-9._-]: $value" >&2
        exit 1
    fi
done

APP="build/DevTidy.app"

BINARIES=()
for ARCH in arm64 x86_64; do
    echo "==> swift build -c release --arch $ARCH"
    swift build -c release --arch "$ARCH"
    BIN="$(swift build -c release --arch "$ARCH" --show-bin-path)"
    if [[ ! -x "$BIN/DevTidy" ]]; then
        echo "bundle.sh: $BIN/DevTidy was not produced" >&2
        exit 1
    fi
    BINARIES+=("$BIN/DevTidy")
done

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/DevTidy" "${BINARIES[@]}"
echo "    architectures: $(lipo -archs "$APP/Contents/MacOS/DevTidy")"

sed -e "s|__BUNDLE_ID__|$BUNDLE_ID|g" \
    -e "s|__VERSION__|$VERSION|g" \
    -e "s|__BUILD__|$BUILD|g" \
    Resources/Info.plist > "$APP/Contents/Info.plist"

# Optional icon: absent by default.
if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
    plutil -insert CFBundleIconFile -string AppIcon "$APP/Contents/Info.plist"
fi

plutil -lint "$APP/Contents/Info.plist"

case "$SIGN" in
    none)
        echo "==> signing skipped (SIGN=none)"
        ;;
    adhoc)
        echo "==> codesign (ad hoc)"
        codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
        codesign --verify --strict --deep "$APP"
        ;;
    *)
        echo "==> codesign ($SIGN, hardened runtime)"
        codesign --force --options runtime --timestamp --sign "$SIGN" --identifier "$BUNDLE_ID" "$APP"
        codesign --verify --strict --deep "$APP"
        ;;
esac

echo "$PWD/$APP"
