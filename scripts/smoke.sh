#!/usr/bin/env bash
# Live smoke test (design §9.3). Operates ONLY on a throwaway project under $HOME and a throwaway
# `python3 -m http.server` it spawns itself. Docker is touched read-only (by LiveSmokeTests).
#
#   case A: the server runs in its own process group  (group kill path)
#   case B: the server shares this script's group     (individual kill path; the script must survive)
#
# Prints `SMOKE OK` on success. Bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

# With HOME empty or relative `$HOME/devtidy-smoke-*` would be a path in the root or in the cwd: refuse before creating anything.
if [[ -z "${HOME:-}" || "$HOME" != /* || "$HOME" == "/" || ! -d "$HOME" ]]; then
    echo "smoke.sh: HOME must be an absolute path to an existing directory (got '${HOME:-}')" >&2
    exit 1
fi

if [[ -n "${DEVTIDY_SMOKE_DIR:-}" ]]; then
    echo "smoke.sh: DEVTIDY_SMOKE_DIR is already set; refusing to run" >&2
    exit 1
fi

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [[ -d "$DEVELOPER_DIR" ]]; then export DEVELOPER_DIR; else unset DEVELOPER_DIR; fi

# Depth 1 under $HOME; the project (depth 2) passes the R1 depth gate. A /tmp project would be refused by design.
SMOKE="$HOME/devtidy-smoke-$(uuidgen | cut -c1-8)"
PROJ="$SMOKE/proj"
SPAWNED=""   # space-separated PIDs this script started itself

cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    local pid
    for pid in $SPAWNED; do
        # Only ever kill a PID this script spawned, and only if it still looks like our http.server.
        if kill -0 "$pid" 2>/dev/null && ps -o command= -p "$pid" 2>/dev/null | grep -q "http.server"; then
            kill "$pid" 2>/dev/null || true
        fi
    done
    case "$SMOKE" in
        "$HOME"/devtidy-smoke-*) rm -rf "$SMOKE" ;;
        *) echo "smoke.sh: refusing to remove '$SMOKE'" >&2 ;;
    esac
    exit "$rc"
}
trap cleanup EXIT INT TERM

# --- throwaway project ------------------------------------------------------------------------------------
mkdir -p "$PROJ/src" "$PROJ/public" "$PROJ/node_modules/dep"
printf '%s\n' '{"name":"devtidy-smoke","devDependencies":{"next":"0.0.0"}}' > "$PROJ/package.json"
printf '%s\n' '.next' > "$PROJ/.gitignore"
printf '%s\n' 'keep' > "$PROJ/src/keep.txt"
printf '%s\n' 'SECRET=1' > "$PROJ/.env"
printf '%s\n' 'logo' > "$PROJ/public/logo.txt"
# The throwaway http.server answers `GET /` with this page (a bare directory listing is a placeholder title, not a title).
printf '%s\n' '<!doctype html><html><head><title>DevTidy Smoke</title></head><body>ok</body></html>' > "$PROJ/index.html"
printf '%s\n' 'module.exports = 1' > "$PROJ/node_modules/dep/index.js"
(
    cd "$PROJ"
    git init -q
    git add package.json .gitignore src public index.html
    git -c user.name=devtidy-smoke -c user.email=smoke@example.invalid -c commit.gpgsign=false commit -qm init
)

make_next_dir() {
    mkdir -p "$PROJ/.next/dev" "$PROJ/.next/cache"
    : > "$PROJ/.next/dev/lock"
    dd if=/dev/zero of="$PROJ/.next/cache/x.bin" bs=1024 count=1024 2>/dev/null
}

port_is_closed() {
    # Subshell so the redirection failure does not trip `set -e`.
    ! (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

for CASE in A B; do
    echo "==> smoke case $CASE"
    make_next_dir
    rm -f "$SMOKE/out.txt" "$SMOKE/pid"

    if [[ "$CASE" == "A" ]]; then
        # Own process group: job control makes the background job a group leader.
        ( set -m; cd "$PROJ"; python3 -u -m http.server 0 --bind 127.0.0.1 >"$SMOKE/out.txt" 2>&1 & echo $! >"$SMOKE/pid" )
    else
        # Shares this script's process group.
        ( cd "$PROJ"; python3 -u -m http.server 0 --bind 127.0.0.1 >"$SMOKE/out.txt" 2>&1 & echo $! >"$SMOKE/pid" )
    fi

    # Wait up to 5 s for the "Serving HTTP on 127.0.0.1 port N" line.
    PORT=""
    for _ in $(seq 1 50); do
        if [[ -s "$SMOKE/pid" && -s "$SMOKE/out.txt" ]]; then
            PORT="$(sed -n 's/.*Serving HTTP on 127\.0\.0\.1 port \([0-9][0-9]*\).*/\1/p' "$SMOKE/out.txt" | head -n 1)"
            [[ -n "$PORT" ]] && break
        fi
        sleep 0.1
    done
    if [[ -z "$PORT" ]]; then
        echo "smoke.sh: http.server did not report a port within 5 s" >&2
        cat "$SMOKE/out.txt" >&2 || true
        exit 1
    fi
    SERVER_PID="$(cat "$SMOKE/pid")"
    SPAWNED="$SPAWNED $SERVER_PID"
    echo "    server pid $SERVER_PID on port $PORT"

    (
        cd "$ROOT"
        DEVTIDY_SMOKE_DIR="$SMOKE" \
        DEVTIDY_SMOKE_CASE="$CASE" \
        DEVTIDY_SMOKE_PORT="$PORT" \
        DEVTIDY_SMOKE_PID="$SERVER_PID" \
        DEVTIDY_SMOKE_SCRIPT_PID="$$" \
        swift test --filter LiveSmokeTests
    )

    if ! port_is_closed "$PORT"; then
        echo "smoke.sh: port $PORT is still open after case $CASE" >&2
        exit 1
    fi
    if [[ -e "$PROJ/.next" ]]; then
        echo "smoke.sh: $PROJ/.next still exists after case $CASE" >&2
        exit 1
    fi
done

echo "SMOKE OK"
