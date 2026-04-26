#!/usr/bin/env bash
# Build, install, and request TCC permissions for MeetingCapture.
# Idempotent: safe to re-run after rebuilds.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

INSTALL_DIR="$HOME/.local/bin"
INSTALL_PATH="$INSTALL_DIR/meetingcapture"

bold()  { printf "\033[1m%s\033[0m\n" "$*"; }
info()  { printf "  %s\n" "$*"; }
warn()  { printf "\033[33m  ! %s\033[0m\n" "$*"; }
fail()  { printf "\033[31m  ✗ %s\033[0m\n" "$*" >&2; exit 1; }
ok()    { printf "\033[32m  ✓ %s\033[0m\n" "$*"; }

# ─── 1. Preflight ────────────────────────────────────────────────────────────
bold "[1/6] Preflight"
[[ "$(uname -s)" == "Darwin" ]] || fail "macOS only."

macos_major="$(sw_vers -productVersion | cut -d. -f1)"
if (( macos_major < 14 )); then
    warn "macOS 14+ recommended (you have $(sw_vers -productVersion)). WhisperKit may not work."
fi

command -v swift >/dev/null 2>&1 || fail "swift not found. Install Xcode or the Command Line Tools: xcode-select --install"
ok "macOS $(sw_vers -productVersion), $(swift --version | head -1)"

# ─── 2. Build ────────────────────────────────────────────────────────────────
bold "[2/6] Build (release)"
swift build -c release
BUILD_BIN=".build/release/MeetingCaptureCLI"
[[ -x "$BUILD_BIN" ]] || fail "Build did not produce $BUILD_BIN"
ok "Built $BUILD_BIN"

# ─── 3. Install ──────────────────────────────────────────────────────────────
bold "[3/6] Install → $INSTALL_PATH"
mkdir -p "$INSTALL_DIR"
install -m 0755 "$BUILD_BIN" "$INSTALL_PATH"
ok "Installed."

case ":$PATH:" in
    *":$INSTALL_DIR:"*) ok "$INSTALL_DIR is on PATH." ;;
    *)
        warn "$INSTALL_DIR is NOT on PATH."
        rc_file="$HOME/.zshrc"
        [[ "${SHELL:-}" == */bash ]] && rc_file="$HOME/.bashrc"
        info "Add this line to $rc_file:"
        info "    export PATH=\"\$HOME/.local/bin:\$PATH\""
        ;;
esac

# ─── 4. Microphone permission ────────────────────────────────────────────────
bold "[4/6] Microphone permission"
info "Triggering the mic prompt — click Allow if macOS asks."
if "$INSTALL_PATH" --permission-probe >/dev/null 2>&1; then
    ok "Mic probe completed."
else
    warn "Mic probe failed. Open Settings and verify meetingcapture is checked under Microphone."
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone" 2>/dev/null || true
fi

# ─── 5. Screen Recording permission ──────────────────────────────────────────
bold "[5/6] Screen Recording permission"
info "macOS requires you to add the binary by hand (no API to grant it)."
info "Path to add:  $INSTALL_PATH"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture" 2>/dev/null || true
open -R "$INSTALL_PATH" 2>/dev/null || true

osascript <<EOF >/dev/null 2>&1 || true
display dialog "In System Settings → Privacy & Security → Screen Recording, click + and add:

$INSTALL_PATH

A Finder window has been opened at the binary's location to make this easier.

Click OK once you've added (and enabled) it." buttons {"OK"} default button 1 with title "MeetingCapture install"
EOF

# ─── 6. Verify ───────────────────────────────────────────────────────────────
bold "[6/6] Verify"
if "$INSTALL_PATH" --list >/dev/null 2>&1; then
    ok "meetingcapture --list succeeded."
else
    warn "meetingcapture --list failed. Likely the Screen Recording grant is missing or attached to the wrong path."
    info "Re-open Privacy & Security → Screen Recording and confirm $INSTALL_PATH is listed and enabled."
fi

echo
bold "Done."
info "Run it:  meetingcapture"
info "        (or $INSTALL_PATH if not on PATH yet)"
