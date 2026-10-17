#!/usr/bin/env bash
# Builds a universal (arm64 + x86_64) release DevTidy.app (menu bar app, LSUIElement) into build/DevTidy.app.
# Each architecture is built separately and the two executables are joined with `lipo -create`.
# Sparkle.framework (a universal binary from the SwiftPM artifact) is embedded into Contents/Frameworks and signed with the app.
#
# Env knobs:
#   VERSION    CFBundleShortVersionString      (default 0.1.0)
#   BUILD      CFBundleVersion                 (default date +%Y%m%d%H%M)
#   BUNDLE_ID  CFBundleIdentifier              (default dev.minata.DevTidy)
#   SIGN       adhoc (default) | none | <codesign identity>
#              An identity signs with the hardened runtime and a secure timestamp (Developer ID / notarization ready).
#              Signing is inside-out, in Sparkle's documented order: Autoupdate, Updater.app, Sparkle.framework, then the app
#              (never `--deep`). Ad hoc signs the same pieces without runtime/timestamp, so local builds verify too.
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

# Sparkle.framework from the resolved SwiftPM binary artifact (already downloaded by the `swift build`s above).
SPARKLE_SRC=""
for candidate in .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-*/Sparkle.framework; do
    if [[ -d "$candidate" ]]; then
        if [[ -n "$SPARKLE_SRC" ]]; then
            echo "bundle.sh: more than one Sparkle.framework slice under .build/artifacts/sparkle" >&2
            exit 1
        fi
        SPARKLE_SRC="$candidate"
    fi
done
if [[ -z "$SPARKLE_SRC" ]]; then
    echo "bundle.sh: Sparkle.framework not found under .build/artifacts/sparkle (run: swift package resolve)" >&2
    exit 1
fi

echo "==> embedding Sparkle.framework"
FW="$APP/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE_SRC" "$FW"   # ditto preserves the Versions/Current and top-level symlinks and the executable bits
FWV="$FW/Versions/$(readlink "$FW/Versions/Current")"
if [[ ! -x "$FWV/Autoupdate" || ! -d "$FWV/Updater.app" ]]; then
    echo "bundle.sh: unexpected Sparkle.framework layout (no Autoupdate / Updater.app in $FWV)" >&2
    exit 1
fi
# DevTidy is not sandboxed, so Sparkle's Installer/Downloader XPC services are never used (Sparkle docs, "Removing XPC Services");
# dropping them also removes two nested code objects to sign and notarize. Headers/modules are build-time only.
rm -rf "$FW/XPCServices" "$FWV/XPCServices" \
    "$FW/Headers" "$FWV/Headers" "$FW/PrivateHeaders" "$FWV/PrivateHeaders" "$FW/Modules" "$FWV/Modules"

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

# sign_inside_out <codesign args shared by every nested code object> -- <extra args for the app>
sign_inside_out() {
    local shared=() app_extra=() seen_sep=0 arg
    for arg in "$@"; do
        if [[ "$arg" == "--" ]]; then seen_sep=1
        elif [[ "$seen_sep" == 0 ]]; then shared+=("$arg")
        else app_extra+=("$arg"); fi
    done
    # Sparkle's order (sparkle-project.org/documentation/sandboxing, "Code Signing"); the XPC services are already removed.
    codesign --force "${shared[@]}" "$FWV/Autoupdate"
    codesign --force "${shared[@]}" "$FWV/Updater.app"
    codesign --force "${shared[@]}" "$FW"
    codesign --force "${shared[@]}" "${app_extra[@]}" "$APP"
    codesign --verify --strict --deep "$APP"
}

case "$SIGN" in
    none)
        echo "==> signing skipped (SIGN=none)"
        ;;
    adhoc)
        echo "==> codesign (ad hoc, inside-out)"
        sign_inside_out --sign - -- --identifier "$BUNDLE_ID"
        ;;
    *)
        echo "==> codesign ($SIGN, hardened runtime, inside-out)"
        sign_inside_out --options runtime --timestamp --sign "$SIGN" -- --identifier "$BUNDLE_ID"
        ;;
esac

echo "$PWD/$APP"
