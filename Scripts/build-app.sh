#!/usr/bin/env bash
# Builds dist/Zipper.app from the Swift package, without Xcode's project (useful for quick local
# builds and CI). Release builds for distribution should use the Xcode project (project.yml), which
# also embeds the Quick Look extension, compiles the asset catalog and the Shortcuts metadata.
#
#   Scripts/build-app.sh [--universal] [--sign "Developer ID Application: Name (TEAMID)"] [--appstore]
#
# Without --sign the app is ad-hoc signed: it runs on this Mac, but Gatekeeper blocks it elsewhere
# until it is signed with a Developer ID and notarized (Scripts/notarize.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
NAME="Zipper"
# Identity and version come from project.yml so both build paths agree.
setting() { grep -E "^\s+$1:" project.yml | head -1 | sed -E "s/^[^:]+:[[:space:]]*\"?([^\"#]*[^\"#[:space:]])\"?.*/\1/"; }
BUNDLE_ID="${BUNDLE_ID:-$(setting ZIPPER_BUNDLE_ID)}"
VERSION="$(setting MARKETING_VERSION)"
BUILD="$(setting CURRENT_PROJECT_VERSION)"
COPYRIGHT="$(setting ZIPPER_COPYRIGHT)"
ARCH_ARGS=(--arch arm64)
SIGN_ID="-"
ENTITLEMENTS="Sources/ZipperMac/Zipper.entitlements"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --universal) ARCH_ARGS=(--arch arm64 --arch x86_64) ;;
    --sign) SIGN_ID="$2"; shift ;;
    --appstore) ENTITLEMENTS="Packaging/Zipper-AppStore.entitlements" ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ ! -d Vendor/macos/xcframeworks/CArchive.xcframework ]]; then
  echo "note: Vendor/macos not built; using Homebrew's libarchive/brotli/xz (run Scripts/build-deps-macos.sh for a self-contained app)"
  export PKG_CONFIG_PATH="$(brew --prefix libarchive)/lib/pkgconfig:$(brew --prefix brotli)/lib/pkgconfig:$(brew --prefix xz)/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
fi

swift build -c release "${ARCH_ARGS[@]}" --product ZipperMac
swift build -c release "${ARCH_ARGS[@]}" --product zipper
BIN="$(swift build -c release "${ARCH_ARGS[@]}" --show-bin-path)"

APP="$ROOT/dist/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources/Licenses"
cp "$BIN/ZipperMac" "$APP/Contents/MacOS/$NAME"
cp "$BIN/zipper" "$APP/Contents/Helpers/zipper"
find "$BIN" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$APP/Contents/Resources/" \;

# Info.plist with Xcode's build variables substituted.
sed -e "s|\$(PRODUCT_BUNDLE_IDENTIFIER)|$BUNDLE_ID|g" \
    -e "s|\$(EXECUTABLE_NAME)|$NAME|g" \
    -e "s|\$(PRODUCT_NAME)|$NAME|g" \
    -e "s|\$(MARKETING_VERSION)|$VERSION|g" \
    -e "s|\$(CURRENT_PROJECT_VERSION)|$BUILD|g" \
    -e "s|\$(ZIPPER_COPYRIGHT)|$COPYRIGHT|g" \
    Sources/ZipperMac/Info.plist > "$APP/Contents/Info.plist"
if grep -q '\$(' "$APP/Contents/Info.plist"; then
  echo "error: unsubstituted build variables left in Info.plist:" >&2
  grep -n '\$(' "$APP/Contents/Info.plist" >&2
  exit 1
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Helpers: 7-Zip (bundled, LGPL) and, optionally, The Unarchiver's command-line tools (LGPL).
if [[ -x Vendor/macos/helpers/7zz ]]; then
  cp Vendor/macos/helpers/7zz "$APP/Contents/Helpers/7zz"
  cp Vendor/macos/helpers/7-Zip-License.txt "$APP/Contents/Resources/Licenses/"
fi
for t in unar lsar; do [[ -x "Vendor/macos/helpers/$t" ]] && cp "Vendor/macos/helpers/$t" "$APP/Contents/Helpers/$t"; done
cp Documentation/Dependencies.md "$APP/Contents/Resources/Licenses/README.md"

# Sign inside-out (helpers first, then the app) with the hardened runtime.
SIGN_ARGS=(--force --options runtime --timestamp)
[[ "$SIGN_ID" == "-" ]] && SIGN_ARGS=(--force --options runtime --timestamp=none)
HELPER_ENT=()
[[ "$ENTITLEMENTS" == Packaging/Zipper-AppStore.entitlements ]] && HELPER_ENT=(--entitlements Packaging/Helper-Inherit.entitlements)
for h in "$APP"/Contents/Helpers/*; do codesign "${SIGN_ARGS[@]}" "${HELPER_ENT[@]}" --sign "$SIGN_ID" "$h"; done
codesign "${SIGN_ARGS[@]}" --entitlements "$ENTITLEMENTS" --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "Built $APP ($VERSION, build $BUILD, $BUNDLE_ID)"
[[ "$SIGN_ID" == "-" ]] && echo "Ad-hoc signed: runs on this Mac only. Sign with --sign and notarize before distributing."
exit 0
