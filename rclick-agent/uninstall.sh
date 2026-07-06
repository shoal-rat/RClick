#!/bin/zsh
# Remove RClick Agent's auto-start and (optionally) disable the Finder extension.
# Leaves the built app in place; pass --purge to also delete the app and its
# support files.
set -euo pipefail

LABEL="dev.zwk.rclick-agent"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
EXT_ID="cn.wflixu.RClick.FinderSyncExt"
APP="/Users/zwk/Applications/RClick Agent.app"
UID_="$(id -u)"

launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null || true
rm -f "$PLIST_DST"
pkill -f "RClick Agent.app/Contents/MacOS/RClick Agent" 2>/dev/null || true
echo "Auto-start removed; agent stopped."

# Disable the Finder extension so its menu disappears
pluginkit -e ignore -i "$EXT_ID" 2>/dev/null || true
killall Finder 2>/dev/null || true
echo "Finder extension disabled."

if [ "${1:-}" = "--purge" ]; then
  rm -rf "$APP"
  rm -rf "$HOME/Library/Application Support/RClick Agent"
  echo "Purged app and support files."
fi

echo "Done."
