#!/usr/bin/env bash
# Packages dist/Universal Archiver.app into a compressed, read-only DMG with an Applications link.
#   Scripts/make-dmg.sh [--sign "Developer ID Application: Name (TEAMID)"]
set -euo pipefail
cd "$(dirname "$0")/.."
APP="dist/Universal Archiver.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="dist/UniversalArchiver-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp Documentation/Installation.md "$STAGE/Read Me.md" 2>/dev/null || true
rm -f "$DMG"
hdiutil create -volname "Universal Archiver" -srcfolder "$STAGE" -fs APFS -format ULFO "$DMG"
if [[ "${1:-}" == "--sign" ]]; then codesign --force --timestamp --sign "$2" "$DMG"; fi
echo "Created $DMG"
