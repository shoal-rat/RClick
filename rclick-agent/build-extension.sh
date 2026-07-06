#!/bin/zsh
# Build the FinderSync extension binary from this fork's sources WITHOUT Xcode
# (plain swiftc from the Command Line Tools) and graft it into an installed
# RClick.app bundle, then ad-hoc re-sign and re-register the extension.
#
# Why grafting: the full RClick.app is a SwiftUI app that needs Xcode to
# build, but the app never runs in the agent setup — only its extension does.
# Taking the upstream release bundle (resources, Info.plist, localizations)
# and replacing just the extension's Mach-O with one compiled from this
# fork's patched sources yields a fully source-fixed extension: no app-group
# read (no TCC prompt) and whole-disk menu coverage.
#
# Usage:  ./build-extension.sh [path-to-RClick.app]   (default /Applications/RClick.app)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
APP="${1:-/Applications/RClick.app}"
APPEX="$APP/Contents/PlugIns/FinderSyncExt.appex"
BIN="$APPEX/Contents/MacOS/FinderSyncExt"
BUILD="$HERE/build"
EXT_ID="cn.wflixu.RClick.FinderSyncExt"

if [[ ! -f "$BIN" ]]; then
  echo "error: $APPEX not found." >&2
  echo "Install the upstream RClick release into /Applications first" >&2
  echo "(https://github.com/wflixu/RClick/releases), then re-run." >&2
  exit 1
fi

mkdir -p "$BUILD"

echo "Compiling extension from fork sources..."
swiftc -O -wmo -parse-as-library \
  -module-name FinderSyncExt \
  -application-extension \
  -Xlinker -e -Xlinker _NSExtensionMain \
  -o "$BUILD/FinderSyncExt" \
  "$REPO/FinderSyncExt/FinderSyncExt.swift" \
  "$REPO/Shared/AppLocalization.swift" \
  "$REPO/Shared/FileTypeIconProvider.swift" \
  "$REPO/Shared/IconCache.swift" \
  "$REPO/Shared/MessageSecurity.swift" \
  "$REPO/Shared/Messager.swift" \
  "$REPO/Shared/RCBase.swift"

# Preserve the bundle's entitlements (sandbox etc.) across the re-sign.
codesign -d --entitlements :- "$APPEX" > "$BUILD/appex.entitlements" 2>/dev/null
codesign -d --entitlements :- "$APP"   > "$BUILD/app.entitlements"   2>/dev/null

echo "Stopping running extension processes..."
pkill -f "FinderSyncExt.appex/Contents/MacOS/FinderSyncExt" 2>/dev/null || true

echo "Grafting binary into $APPEX ..."
cp "$BUILD/FinderSyncExt" "$BIN"
xattr -cr "$APP"

echo "Ad-hoc signing (extension first, then the app so the seal covers it)..."
codesign --force --sign - --entitlements "$BUILD/appex.entitlements" --options runtime "$APPEX"
codesign --force --sign - --entitlements "$BUILD/app.entitlements"   --options runtime "$APP"
codesign --verify --strict --deep "$APP" && echo "codesign: verified"

echo "Registering and enabling the extension..."
pluginkit -a "$APPEX" 2>/dev/null || true
pluginkit -e use -i "$EXT_ID"

echo "Restarting Finder..."
killall Finder 2>/dev/null || true

echo "Done. Right-click in any folder to check the menu."
echo "(If items are missing, make sure the agent is installed: ./build.sh && ./install.sh)"
