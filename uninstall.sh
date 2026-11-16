#!/usr/bin/env bash
set -euo pipefail
LABEL="com.shuttle.ejectd"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/.local/bin/shuttle"
echo "✓ agent removed. Config in ~/.config/shuttle and cached data on the SSD were left alone."
