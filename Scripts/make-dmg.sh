#!/usr/bin/env bash
# Packages a signed Zipper.app into a compressed, read-only DMG with an Applications shortcut.
#
#   Scripts/make-dmg.sh [path/to/Zipper.app] [--sign "Developer ID Application: Name (TEAMID)"]
#
# The app defaults to dist/Zipper.app (Scripts/build-app.sh, or Xcode's exported app copied there).
# Notarize the result with Scripts/notarize.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="dist/Zipper.app"
SIGN_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sign) SIGN_ID="$2"; shift ;;
    *.app) APP="$1" ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
[[ -d "$APP" ]] || { echo "No app at $APP. Build or export it first." >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
mkdir -p dist
DMG="dist/Zipper-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Zipper.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Zipper $VERSION" -srcfolder "$STAGE" -fs APFS -format ULFO "$DMG"
if [[ -n "$SIGN_ID" ]]; then codesign --force --timestamp --sign "$SIGN_ID" "$DMG"; fi
echo "Created $DMG"
