#!/bin/bash
# uninstall.command — Ogma uninstaller for macOS
# Double-click this file in Finder to run.

set -e

# Guard Terminal.app-specific AppleScript (user may use iTerm2, Warp, etc.)
_IS_TERMINAL_APP=false
[ "$TERM_PROGRAM" = "Apple_Terminal" ] && _IS_TERMINAL_APP=true

# ── Capture Terminal window ID for cleanup ────────────────────────
_TERM_WINDOW_ID=""
if $_IS_TERMINAL_APP; then
    _TERM_WINDOW_ID=$(osascript -e 'tell application "Terminal" to id of front window' 2>/dev/null || true)
fi

# ── Cleanup ───────────────────────────────────────────────────────
cleanup() {
    if $_IS_TERMINAL_APP && [ -n "$_TERM_WINDOW_ID" ]; then
        osascript -e "tell application \"Terminal\" to close (every window whose id is $_TERM_WINDOW_ID)" 2>/dev/null &
    fi
}
trap cleanup EXIT

result=$(osascript -e 'button returned of (display dialog "This will completely remove Ogma:\n\n  • Stop and remove the menu bar app\n  • Remove Accessibility permission\n  • Remove the speak script\n  • Remove the Services workflow\n  • Remove settings and config\n  • Remove the local TTS environment\n  • Remove the API key from Keychain\n  • Remove the login item (if set)" with title "Ogma" buttons {"Cancel", "Uninstall"} default button "Cancel" with icon caution)' 2>/dev/null || true)
[ "$result" = "Uninstall" ] || exit 0

printf '\033[2J\033[H'
printf '\n'
printf '  \033[1mOgma\033[0m — Uninstalling\n'
printf '  ───────────────────────\n\n'

step() { printf '  \033[32m✓\033[0m  %s\n' "$1"; }

# ── Quit the menu bar app ─────────────────────────────────────────
pkill -x "Ogma" 2>/dev/null || true
sleep 0.5
step "Menu bar app stopped"

# ── Remove Accessibility permission ───────────────────────────────
tccutil reset Accessibility com.ogma.app 2>/dev/null || true
step "Accessibility permission removed"

# ── Remove the app bundle ─────────────────────────────────────────
rm -rf "$HOME/Applications/Ogma.app"
# pkg installs land in /Applications; the receipt forget needs root and
# is harmless if left behind, so both are best-effort.
rm -rf "/Applications/Ogma.app" 2>/dev/null || true
pkgutil --forget com.ogma.app 2>/dev/null || true
step "App bundle removed"

# ── Remove scripts ────────────────────────────────────────────────
rm -f "$HOME/.local/bin/speak.sh"
rm -f "$HOME/.local/bin/tts_server.py"
rm -f "$HOME/.local/bin/stt_server.py"
rm -f "$HOME/.local/bin/install-local.sh"
rm -f "$HOME/.local/bin/uninstall.command"
rm -f "$HOME/.local/bin/ogma-audio"
step "Scripts removed"

# ── Remove the Services workflow ──────────────────────────────────
rm -rf "$HOME/Library/Services/Speak Selection.workflow"
step "Quick Action removed"

# ── Remove config directory ───────────────────────────────────────
rm -rf "$HOME/.config/ogma"
step "Config removed"

# ── Kill TTS/STT daemons if running ──────────────────────────────
for _svc in tts_server stt_server; do
    _pidfile="$HOME/.local/share/ogma/${_svc}.pid"
    if [ -f "$_pidfile" ]; then
        _daemon_pid=$(cat "$_pidfile" 2>/dev/null)
        if [ -n "$_daemon_pid" ] && kill -0 "$_daemon_pid" 2>/dev/null; then
            if ps -p "$_daemon_pid" -o args= 2>/dev/null | grep -q "$_svc"; then
                kill "$_daemon_pid" 2>/dev/null || true
            fi
        fi
    fi
done

# ── Remove local TTS data (venv, daemon, standalone Python) ────
rm -rf "$HOME/.local/share/ogma"
step "Local TTS data removed"

# ── Remove API key from Keychain ──────────────────────────────────
security delete-generic-password \
    -a "ogma" \
    -s "ogma-api-key" 2>/dev/null || true
step "API key removed from Keychain"


# ── Remove login item ────────────────────────────────────────────
osascript -e 'tell application "System Events" to delete (every login item whose name is "Ogma")' 2>/dev/null || true
osascript -e 'tell application "System Events" to delete (every login item whose name is "Ogma Settings")' 2>/dev/null || true
step "Login item removed"

# ── Remove installer lock if stale ────────────────────────────────
rmdir /tmp/ogma_install.lock 2>/dev/null || rm -rf /tmp/ogma_install.lock 2>/dev/null || true

printf '\n  \033[32mOgma has been removed.\033[0m\n\n'

# ── Done ──────────────────────────────────────────────────────────
osascript -e 'display dialog "Ogma has been removed.\n\nIf you assigned a Services keyboard shortcut, remove it manually:\nSystem Settings → Keyboard → Keyboard Shortcuts → Services" with title "Ogma" buttons {"Done"} default button "Done" with icon note' 2>/dev/null || true
