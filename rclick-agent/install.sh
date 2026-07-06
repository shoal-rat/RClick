#!/bin/zsh
# Install RClick Agent so it runs at every login and enable the RClick Finder
# extension. Idempotent: safe to re-run after a rebuild.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="/Users/zwk/Applications/RClick Agent.app"
LABEL="dev.zwk.rclick-agent"
PLIST_SRC="$HERE/$LABEL.plist"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
EXT_ID="cn.wflixu.RClick.FinderSyncExt"
UID_="$(id -u)"

[ -d "$APP" ] || { echo "error: build first ($APP not found). Run ./build.sh"; exit 1; }

# 1. LaunchAgent
mkdir -p "$HOME/Library/LaunchAgents"
cp "$PLIST_SRC" "$PLIST_DST"
launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null || true
# Kill any manually-opened copy so the launchd-managed copy wins the
# single-instance lock and becomes the one true instance.
pkill -f "RClick Agent.app/Contents/MacOS/RClick Agent" 2>/dev/null || true
sleep 1
launchctl bootstrap "gui/$UID_" "$PLIST_DST"
launchctl enable "gui/$UID_/$LABEL"
launchctl kickstart -k "gui/$UID_/$LABEL" 2>/dev/null || true
echo "LaunchAgent installed and started."

# 2. Enable the RClick Finder extension (source of the top-level right-click menu)
pluginkit -e use -i "$EXT_ID" && echo "Finder extension enabled."

# 3. Restart Finder so the extension reloads
killall Finder 2>/dev/null || true

echo
echo "Done. Right-click a file or folder in Finder to see the RClick menu."
echo "The agent is invisible (no Dock/menubar icon) and starts automatically at login."
echo
echo "Optional, for fully prompt-free file actions in Desktop/Documents/Downloads:"
echo "  grant \"RClick Agent\" Full Disk Access in"
echo "  System Settings > Privacy & Security > Full Disk Access."
echo "  (One-time; otherwise macOS may ask once per protected folder.)"
