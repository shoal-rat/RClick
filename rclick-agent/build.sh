#!/bin/zsh
# Build "RClick Agent.app" — an invisible (LSUIElement/accessory) background app
# that drives the original signed RClick FinderSync extension over its IPC
# protocol. Compiles against RClick's own Shared/ sources for protocol fidelity.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# RClick sources for the Shared/ IPC files. Override with RCLICK_SRC=…;
# auto-detects the enclosing repo when this directory lives inside the RClick
# fork, else falls back to the local vendored checkout.
if [[ -z "${RCLICK_SRC:-}" ]]; then
  if [[ -f "$HERE/../Shared/Messager.swift" ]]; then
    RCLICK_SRC="$(cd "$HERE/.." && pwd)"
  else
    RCLICK_SRC="/Users/zwk/Documents/Codex/2026-07-05/pl-2/work/rclick/RClick-src"
  fi
fi
APP="/Users/zwk/Applications/RClick Agent.app"
BUILD="$HERE/build"
LABEL="dev.zwk.rclick-agent"

# Stop any running copy first so `rm -rf "$APP"` can't be respawned from a
# half-written bundle. If the LaunchAgent is loaded, bootout; otherwise just
# kill the process.
if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  echo "Stopping loaded LaunchAgent..."
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
fi
pkill -f "RClick Agent.app/Contents/MacOS/RClick Agent" 2>/dev/null || true

rm -rf "$BUILD"
mkdir -p "$BUILD"

swiftc \
  -O -wmo -parse-as-library \
  -o "$BUILD/RClick Agent" \
  "$RCLICK_SRC/Shared/MessageSecurity.swift" \
  "$RCLICK_SRC/Shared/Messager.swift" \
  "$HERE/RCBaseSubset.swift" \
  "$HERE/main.swift"

# Assemble bundle
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
cp "$BUILD/RClick Agent" "$APP/Contents/MacOS/RClick Agent"

# Bundle the Office templates — required for "New Word/PowerPoint/Excel".
# Prefer the repo copy next to this script, then the user's App Support copy;
# fail loudly if neither exists.
for f in blank.docx blank.pptx blank.xlsx; do
  if [ -f "$HERE/Templates/$f" ]; then
    cp "$HERE/Templates/$f" "$APP/Contents/Resources/$f"
  elif [ -f "$HOME/Library/Application Support/RClick/Templates/$f" ]; then
    cp "$HOME/Library/Application Support/RClick/Templates/$f" "$APP/Contents/Resources/$f"
  else
    echo "error: missing Office template $f (looked in $HERE/Templates and ~/Library/Application Support/RClick/Templates)" >&2
    exit 1
  fi
done

# Ad-hoc sign after all resources are in place so the seal covers them.
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP" && echo "codesign: verified"
echo "Built: $APP"
