#!/usr/bin/env bash
# Build shuttle and install the eject agent.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.shuttle.ejectd"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/shuttle-ejectd.log"
BIN="$REPO/build/shuttle-ejectd"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$1"; }

bold "Building shuttle-ejectd"
mkdir -p "$REPO/build"
swiftc -O -o "$BIN" "$REPO/src/ejectd/main.swift"
ok "built $BIN"

bold "Checking dependencies"
if [ -x /opt/homebrew/bin/rsync ] || [ -x /usr/local/bin/rsync ]; then
    ok "rsync 3.x present"
else
    warn "only macOS openrsync found; install a modern one:  brew install rsync"
fi

bold "Config"
mkdir -p "$HOME/.config/shuttle"
"$REPO/bin/shuttle" config --init

bold "Installing LaunchAgent"
mkdir -p "$HOME/Library/LaunchAgents" "$(dirname "$LOG")"
sed -e "s|__BINARY__|$BIN|g" -e "s|__LOG__|$LOG|g" \
    "$REPO/launchd/$LABEL.plist.template" > "$PLIST"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
ok "agent loaded"

bold "Linking CLI"
mkdir -p "$HOME/.local/bin"
ln -sf "$REPO/bin/shuttle" "$HOME/.local/bin/shuttle"
ok "linked ~/.local/bin/shuttle"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) warn "add ~/.local/bin to PATH:  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc" ;;
esac

echo
bold "Next steps"
echo "  1. shuttle setup        # NAS credentials + phone alerts"
echo "  2. shuttle notify-test  # confirm the phone alert arrives"
echo "  3. shuttle doctor       # full diagnostic"
