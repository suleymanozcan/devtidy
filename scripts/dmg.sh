#!/usr/bin/env bash
# Packs an app bundle into dist/DevTidy-<version>.dmg: the app plus an /Applications symlink, volume name DevTidy,
# compressed (UDZO).
#
# Usage: scripts/dmg.sh <path/to/DevTidy.app> <version>
#
# Env knobs:
#   SIGN   <codesign identity> signs the DMG (with a secure timestamp); unset, `none` or `adhoc` leave it unsigned
#          (an ad hoc signature on a disk image is of no use).
#
# Prints the DMG path on the last line. Runs from the repository root regardless of the caller's cwd.
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: scripts/dmg.sh <path/to/DevTidy.app> <version>" >&2
    exit 2
fi

# Resolve the app path before changing directory.
if [[ ! -d "$1" ]]; then
    echo "dmg.sh: $1 is not a directory" >&2
    exit 1
fi
APP="$(cd "$1" && pwd)"
VERSION="$2"

if [[ ! -f "$APP/Contents/Info.plist" ]]; then
    echo "dmg.sh: $APP has no Contents/Info.plist (not an app bundle)" >&2
    exit 1
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "dmg.sh: version must look like 0.1.0 (got '$VERSION')" >&2
    exit 1
fi

cd "$(dirname "${BASH_SOURCE[0]}")/.."

SIGN="${SIGN:-none}"
OUT="dist/DevTidy-$VERSION.dmg"

# `mktemp -d` guarantees a fresh, empty directory: the only thing this script ever removes is that directory.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/devtidy-dmg.XXXXXX")"
cleanup() {
    if [[ -n "${STAGE:-}" && -d "$STAGE" ]]; then rm -rf "$STAGE"; fi
}
trap cleanup EXIT

echo "==> staging DevTidy.app + /Applications"
ditto "$APP" "$STAGE/DevTidy.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p dist
rm -f "$OUT"
echo "==> hdiutil create $OUT"
hdiutil create -volname DevTidy -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT" >/dev/null

case "$SIGN" in
    none|adhoc)
        echo "==> DMG signing skipped (SIGN=$SIGN)"
        ;;
    *)
        echo "==> codesign DMG ($SIGN)"
        codesign --force --timestamp --sign "$SIGN" "$OUT"
        codesign --verify --strict "$OUT"
        ;;
esac

echo "$PWD/$OUT"
