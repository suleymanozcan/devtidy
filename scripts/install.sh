#!/usr/bin/env bash
# Builds DevTidy.app (scripts/bundle.sh) and installs it to ~/Applications/DevTidy.app. Never touches /Applications and
# never signals a running DevTidy: restart it yourself after an upgrade.
#
# An existing ~/Applications/DevTidy.app is replaced ONLY if it is a bundle whose CFBundleIdentifier equals BUNDLE_ID.
# The new bundle is staged next to the target and swapped in by rename, so a failed copy leaves the old app in place, and
# so does an interrupt (Ctrl-C, SIGTERM, SIGHUP) between the two renames: the exit handler puts the old app back.
set -euo pipefail

# Checked before anything runs (bundle.sh included): with HOME empty or relative the target would resolve to /Applications.
if [[ -z "${HOME:-}" || "$HOME" != /* || "$HOME" == "/" || ! -d "$HOME" ]]; then
    echo "install.sh: HOME must be an absolute path to an existing directory (got '${HOME:-}')" >&2
    exit 1
fi

cd "$(dirname "${BASH_SOURCE[0]}")/.."

BUNDLE_ID="${BUNDLE_ID:-dev.minata.DevTidy}"
export BUNDLE_ID

DEST_DIR="$HOME/Applications"
DEST="$DEST_DIR/DevTidy.app"
# A symlinked ~/Applications (to /Applications, say) would send the install somewhere else: never install through one.
if [[ -L "$DEST_DIR" ]]; then
    echo "install.sh: refusing to install through the symlink $DEST_DIR" >&2
    exit 1
fi

scripts/bundle.sh

SRC="build/DevTidy.app"

if [[ ! -f "$SRC/Contents/Info.plist" ]]; then
    echo "install.sh: $SRC was not produced" >&2
    exit 1
fi

mkdir -p "$DEST_DIR"
# Same check on what actually exists now: the physical path of the target directory must be <physical HOME>/Applications.
if [[ "$(cd -P "$DEST_DIR" && pwd)" != "$(cd -P "$HOME" && pwd)/Applications" ]]; then
    echo "install.sh: refusing to install to '$DEST_DIR' (it does not resolve to \$HOME/Applications)" >&2
    exit 1
fi

if [[ -e "$DEST" || -L "$DEST" ]]; then
    PLIST="$DEST/Contents/Info.plist"
    if [[ -L "$DEST" || ! -f "$PLIST" ]]; then
        echo "install.sh: refusing to replace $DEST (not a DevTidy bundle: no Contents/Info.plist or a symlink)" >&2
        exit 1
    fi
    EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST" 2>/dev/null || true)"
    if [[ "$EXISTING_ID" != "$BUNDLE_ID" ]]; then
        echo "install.sh: refusing to replace $DEST (CFBundleIdentifier '$EXISTING_ID' != '$BUNDLE_ID')" >&2
        exit 1
    fi
fi

# Stage inside DEST_DIR (same volume, so the final steps are renames). `mktemp -d` guarantees a fresh, empty directory:
# the only thing this script ever removes is that directory.
WORK="$(mktemp -d "$DEST_DIR/.DevTidy-install.XXXXXX")"
KEEP_WORK=0
# "swapping" from just before the old app is moved aside until the new one is in place. If the script exits while it is set
# and $DEST is gone, the old app is in $WORK/previous.app and must go back before $WORK is removed.
SWAP=none
cleanup() {
    if [[ "$SWAP" == "swapping" && ! -e "$DEST" && -e "$WORK/previous.app" ]]; then
        if mv "$WORK/previous.app" "$DEST"; then
            echo "install.sh: interrupted; the previous app was put back" >&2
        else
            KEEP_WORK=1
            echo "install.sh: interrupted and the previous app could not be restored; it is in $WORK/previous.app" >&2
        fi
    fi
    if [[ -n "${WORK:-}" && "$KEEP_WORK" != 1 ]]; then rm -rf "$WORK"; fi
    return 0
}
trap cleanup EXIT
# Turn signals into a normal exit so the EXIT trap above always runs.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

ditto "$SRC" "$WORK/DevTidy.app"
if [[ ! -f "$WORK/DevTidy.app/Contents/Info.plist" ]]; then
    echo "install.sh: copying $SRC failed; $DEST was left untouched" >&2
    exit 1
fi

if [[ -e "$DEST" ]]; then
    SWAP=swapping
    mv "$DEST" "$WORK/previous.app"
    if ! mv "$WORK/DevTidy.app" "$DEST"; then
        # Put the old app back; if even that fails, keep the staging directory so nothing is lost.
        if ! mv "$WORK/previous.app" "$DEST"; then
            KEEP_WORK=1
            echo "install.sh: could not restore the previous app; it is in $WORK/previous.app" >&2
        fi
        echo "install.sh: could not move the new app into place" >&2
        exit 1
    fi
    SWAP=done
else
    mv "$WORK/DevTidy.app" "$DEST"
fi

echo "$DEST"
