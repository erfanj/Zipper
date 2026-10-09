#!/usr/bin/env bash
# Builds Universal Archiver.app from the Swift package (no Xcode project needed for the main app).
#
#   Scripts/build-app.sh [--universal] [--sign "Developer ID Application: Name (TEAMID)"] [--appstore]
#
# Without --sign the app is ad-hoc signed: it runs on this Mac, but Gatekeeper will block it on
# others until it is signed with a Developer ID and notarized (see Scripts/notarize.sh).
# The Quick Look extension and Shortcuts metadata require the Xcode project (project.yml).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
NAME="Universal Archiver"
BUNDLE_ID="${BUNDLE_ID:-com.example.universalarchiver}"
ARCH_ARGS=(--arch arm64)
SIGN_ID="-"
ENTITLEMENTS="Sources/UniversalArchiver/UniversalArchiver.entitlements"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --universal) ARCH_ARGS=(--arch arm64 --arch x86_64) ;;
    --sign) SIGN_ID="$2"; shift ;;
    --appstore) ENTITLEMENTS="Packaging/UniversalArchiver-AppStore.entitlements" ;;
  esac
  shift
done

if [[ -d Vendor/macos/lib/pkgconfig ]]; then
  export PKG_CONFIG_PATH="$ROOT/Vendor/macos/lib/pkgconfig"
else
  echo "note: Vendor/macos not found; using Homebrew libarchive/brotli (run Scripts/build-deps-macos.sh for a self-contained app)"
  export PKG_CONFIG_PATH="$(brew --prefix libarchive)/lib/pkgconfig:$(brew --prefix brotli)/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
fi

swift build -c release "${ARCH_ARGS[@]}" --product UniversalArchiver
swift build -c release "${ARCH_ARGS[@]}" --product archiver
BIN="$(swift build -c release "${ARCH_ARGS[@]}" --show-bin-path)"

APP="$ROOT/dist/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources" "$APP/Contents/Resources/Licenses"
cp "$BIN/UniversalArchiver" "$APP/Contents/MacOS/UniversalArchiver"
cp "$BIN/archiver" "$APP/Contents/Helpers/archiver"
# SwiftPM resource bundles (if any)
find "$BIN" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$APP/Contents/Resources/" \;

# Info.plist with build variables substituted
sed -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/" -e "s/\$(EXECUTABLE_NAME)/UniversalArchiver/" \
  Sources/UniversalArchiver/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
[[ -f Packaging/AppIcon.icns ]] && cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Helpers: 7-Zip (bundled, LGPL) and The Unarchiver CLI (optional, LGPL).
if [[ -x Vendor/macos/helpers/7zz ]]; then
  cp Vendor/macos/helpers/7zz "$APP/Contents/Helpers/7zz"
  cp Vendor/macos/helpers/7-Zip-License.txt "$APP/Contents/Resources/Licenses/"
fi
for t in unar lsar; do [[ -x "Vendor/macos/helpers/$t" ]] && cp "Vendor/macos/helpers/$t" "$APP/Contents/Helpers/$t"; done
cp Documentation/Dependencies.md "$APP/Contents/Resources/Licenses/README.md"

# Sign inside-out: helpers, then the app, with the hardened runtime.
SIGN_ARGS=(--force --options runtime --timestamp)
[[ "$SIGN_ID" == "-" ]] && SIGN_ARGS=(--force --options runtime)
HELPER_ENT=()
[[ "$ENTITLEMENTS" == Packaging/UniversalArchiver-AppStore.entitlements ]] && HELPER_ENT=(--entitlements Packaging/Helper-Inherit.entitlements)
for h in "$APP"/Contents/Helpers/*; do codesign "${SIGN_ARGS[@]}" "${HELPER_ENT[@]}" --sign "$SIGN_ID" "$h"; done
codesign "${SIGN_ARGS[@]}" --entitlements "$ENTITLEMENTS" --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "Built $APP"
[[ "$SIGN_ID" == "-" ]] && echo "Ad-hoc signed: not notarized. Distribute only after signing with a Developer ID and running Scripts/notarize.sh."
