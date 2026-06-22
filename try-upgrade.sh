#!/data/data/com.termux/files/usr/bin/bash
# try-upgrade.sh -- safely test whether a newer Claude Code native build works
# on this Termux/glibc-runner setup, and promote it only if it doesn't crash.
#
# Latest builds (>= 2.1.185) have segfaulted under the bundled Bun on this glibc
# layer, so the live binary is pinned and the wrapper's auto-update is OFF. This
# script lets you re-test "latest" (or a specific version) WITHOUT clobbering the
# working pin: it stages the candidate, smoke-tests it, and swaps it in only on
# success. On failure the pin is untouched.
#
# Usage:
#   ./try-upgrade.sh            # test the latest published version
#   ./try-upgrade.sh 2.1.190    # test a specific version
#
# Exit codes: 0 = upgraded (or already newest), 1 = candidate failed test,
#             2 = setup/download error.

set -u

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${YELLOW}$*${NC}"; }
ok()    { echo -e "${GREEN}$*${NC}"; }
err()   { echo -e "${RED}$*${NC}" >&2; }

PACKAGE="@anthropic-ai/claude-code-linux-arm64"
INSTALL_DIR="/data/data/com.termux/files/usr/lib/node_modules/$PACKAGE"
PACKAGE_JSON="$INSTALL_DIR/package.json"
BINARY_PATH="$INSTALL_DIR/claude"
STAGE_DIR="$HOME/.cache/claude-upgrade"   # avoids /tmp (flaky on this box)
BACKUP_DIR="$HOME/.cache/claude-pin-backup"

# --- figure out current + candidate versions ---------------------------------
if [ -f "$PACKAGE_JSON" ]; then
    # `grep` may be shimmed under glibc-runner; prefer rg, fall back to command grep.
    if command -v rg >/dev/null 2>&1; then
        INSTALLED=$(rg -o '"version":\s*"([^"]+)"' -r '$1' "$PACKAGE_JSON" | head -1)
    else
        INSTALLED=$(command grep '"version":' "$PACKAGE_JSON" | head -1 | cut -d'"' -f4)
    fi
else
    INSTALLED="none"
fi

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
    info "Querying npm for the latest $PACKAGE ..."
    TARGET=$(npm view "$PACKAGE" version 2>/dev/null)
fi

if [ -z "$TARGET" ]; then
    err "Could not determine target version (npm view failed). Check your connection."
    exit 2
fi

echo "Installed: ${INSTALLED:-none}"
echo "Candidate: $TARGET"

if [ "$TARGET" = "$INSTALLED" ]; then
    ok "Already on $TARGET. Nothing to do."
    exit 0
fi

# --- download + stage the candidate (never touches the live binary yet) ------
URL=$(npm view "$PACKAGE@$TARGET" dist.tarball 2>/dev/null)
if [ -z "$URL" ]; then
    err "No tarball URL for $PACKAGE@$TARGET -- is that a real published version?"
    exit 2
fi

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR" || { err "Cannot create $STAGE_DIR"; exit 2; }
TGZ="$STAGE_DIR/candidate.tgz"

info "Downloading $TARGET ..."
if ! wget -q --show-progress "$URL" -O "$TGZ"; then
    err "Download failed."
    rm -rf "$STAGE_DIR"
    exit 2
fi

EXTRACT="$STAGE_DIR/extract"
mkdir -p "$EXTRACT"
if ! tar -xzf "$TGZ" -C "$EXTRACT" --strip-components=1; then
    err "Extraction failed (corrupt download?)."
    rm -rf "$STAGE_DIR"
    exit 2
fi
STAGED_BIN="$EXTRACT/claude"
chmod +x "$STAGED_BIN" 2>/dev/null
if [ ! -f "$STAGED_BIN" ]; then
    err "Extracted package has no 'claude' binary at $STAGED_BIN."
    rm -rf "$STAGE_DIR"
    exit 2
fi

# --- smoke test --------------------------------------------------------------
# IMPORTANT: `--version`/`--help` are NOT enough. The known segfault (Bun 1.4.0
# bundled since 2.1.181) only fires during full *interactive* runtime init --
# `--version` exits cleanly even on crashing builds. So we do two gates:
#   1. a cheap `--version` exit-code check (catches gross breakage), then
#   2. a pty launch of the real interactive runtime, in an isolated $HOME so it
#      can't touch your config/auth, watching ~12s for a SIGSEGV or crash banner.
run_check() {
    local desc="$1"; shift
    local out rc
    out=$(timeout 60 glibc-runner "$STAGED_BIN" "$@" 2>&1)
    rc=$?
    if [ "$rc" -eq 139 ]; then
        err "  [$desc] SEGFAULT (exit 139)."; return 1
    elif [ "$rc" -eq 124 ]; then
        err "  [$desc] timed out (60s)."; return 1
    elif [ "$rc" -ne 0 ]; then
        err "  [$desc] exited $rc:"; echo "$out" | tail -3 >&2; return 1
    fi
    echo "  [$desc] ok (exit 0)"; return 0
}

# Interactive init test via pty. Returns 0 = survived init (good), 1 = crashed.
pty_init_test() {
    local bin="$1"
    command -v python3 >/dev/null 2>&1 || { err "  [interactive] python3 not found -- cannot run pty test"; return 1; }
    python3 - "$bin" <<'PY'
import os, sys, pty, signal, time, select, tempfile, shutil, re
binp = sys.argv[1]
TIMEOUT = 12.0
home = tempfile.mkdtemp(prefix="cc-upgrade-test-")     # isolated: no real config touched
env = dict(os.environ); env["HOME"] = home; env["TERM"] = "xterm-256color"
env.pop("BASH_ENV", None)
pid, fd = pty.fork()
if pid == 0:
    try: os.execvpe("glibc-runner", ["glibc-runner", binp], env)
    except Exception: os._exit(127)
buf = b""; status = None; start = time.time()
while time.time() - start < TIMEOUT:
    try:
        r,_,_ = select.select([fd], [], [], 0.5)
        if r:
            try:
                c = os.read(fd, 4096)
                if c: buf += c
            except OSError: pass
    except Exception: pass
    wpid, wstatus = os.waitpid(pid, os.WNOHANG)
    if wpid == pid: status = wstatus; break
survived = status is None
if survived:
    try: os.kill(pid, signal.SIGKILL); os.waitpid(pid, 0)
    except Exception: pass
try: os.close(fd)
except Exception: pass
shutil.rmtree(home, ignore_errors=True)
blob = buf.decode("utf-8","replace").lower()
crashy = any(s in blob for s in ("segmentation fault","bun has crashed","bun.report","panic","oh no"))
sig = os.WTERMSIG(status) if (status is not None and os.WIFSIGNALED(status)) else None
if survived and not crashy:
    print("  [interactive] ok (survived init, no crash)"); sys.exit(0)
if sig == signal.SIGSEGV or crashy:
    print("  [interactive] CRASH during init (Bun runtime segfault)"); sys.exit(1)
print(f"  [interactive] FAIL (signal={sig}, status={status})"); sys.exit(1)
PY
}

info "Smoke-testing $TARGET under glibc-runner ..."
PASS=1
run_check "--version" --version || PASS=0
pty_init_test "$STAGED_BIN" || PASS=0

if [ "$PASS" -ne 1 ]; then
    err "Candidate $TARGET FAILED the smoke test. Keeping pinned ${INSTALLED}."
    rm -rf "$STAGE_DIR"
    exit 1
fi

# --- promote: back up the working pin, then swap the candidate in ------------
ok "Candidate $TARGET passed. Promoting it."
rm -rf "$BACKUP_DIR"
if [ -d "$INSTALL_DIR" ]; then
    cp -a "$INSTALL_DIR" "$BACKUP_DIR" && echo "Backed up current pin -> $BACKUP_DIR"
fi

# Replace contents in place (keeps the dir/symlinks the wrapper expects).
rm -rf "${INSTALL_DIR:?}/"*
cp -a "$EXTRACT/." "$INSTALL_DIR/"
chmod +x "$BINARY_PATH"
rm -rf "$STAGE_DIR"

ok "=== Upgraded to $TARGET ==="
echo -e "Roll back if needed:  ${BLUE}rm -rf '$INSTALL_DIR'/* && cp -a '$BACKUP_DIR/.' '$INSTALL_DIR/'${NC}"
echo -e "To make it the fresh-install default too, bump ${BLUE}PIN_VERSION=\"$TARGET\"${NC} in install.sh and commit."
exit 0
