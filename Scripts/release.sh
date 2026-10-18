#!/usr/bin/env bash
# Builds a release DMG of Zipper in one go: universal (Apple silicon + Intel) dependencies, Xcode
# archive, export, disk image and checks. With a Developer ID identity it also signs for
# distribution, and with --notarize it notarizes and staples the app and the DMG.
#
#   Scripts/release.sh                       # ad-hoc signed: for testing only (Gatekeeper warns)
#   Scripts/release.sh --sign "Developer ID Application: Your Name (TEAMID)" --team TEAMID --notarize
#
# Notarization credentials: see Scripts/notarize.sh (a keychain profile, or an App Store Connect
# API key in NOTARY_KEY_PATH / NOTARY_KEY_ID / NOTARY_ISSUER). BUILD_NUMBER overrides the build
# number (CURRENT_PROJECT_VERSION in project.yml).
#
# Output: dist/Zipper.app, dist/Zipper-<version>.dmg and dist/Zipper-<version>.dmg.sha256.
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN=""
TEAM=""
NOTARIZE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sign) SIGN="$2"; shift ;;
    --team) TEAM="$2"; shift ;;
    --notarize) NOTARIZE=1 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
if [[ -n "$SIGN" && -z "$TEAM" ]]; then echo "--sign needs --team TEAMID" >&2; exit 2; fi
if [[ $NOTARIZE == 1 && -z "$SIGN" ]]; then echo "--notarize needs --sign (Apple only notarizes Developer ID builds)" >&2; exit 2; fi

step() { printf '\n==> %s\n' "$*"; }
fail() { echo "error: $*" >&2; exit 1; }
mkdir -p build dist

# 1. Universal dependencies (rebuilt only when missing or single-architecture).
step "Dependencies"
LIB="Vendor/macos/xcframeworks/CArchive.xcframework/macos-arm64_x86_64/libCArchive.a"
if [[ -f "$LIB" ]] && lipo "$LIB" -verify_arch arm64 x86_64 2>/dev/null; then
  echo "Universal libraries already built."
else
  Scripts/build-deps-macos.sh --universal
fi

# 2. Xcode project.
step "Project"
command -v xcodegen >/dev/null || fail "XcodeGen is missing: brew install xcodegen"
xcodegen generate --quiet

# 3. Archive (Release, both architectures).
step "Archive"
SETTINGS=()
[[ -n "${BUILD_NUMBER:-}" ]] && SETTINGS+=("CURRENT_PROJECT_VERSION=$BUILD_NUMBER")
if [[ -n "$SIGN" ]]; then
  SETTINGS+=("CODE_SIGN_IDENTITY=$SIGN" "DEVELOPMENT_TEAM=$TEAM" "OTHER_CODE_SIGN_FLAGS=--timestamp")
else
  SETTINGS+=("CODE_SIGN_IDENTITY=-" "DEVELOPMENT_TEAM=")
fi
ARCHIVE=build/Zipper.xcarchive
rm -rf "$ARCHIVE"
if ! xcodebuild -project Zipper.xcodeproj -scheme Zipper -configuration Release -destination 'generic/platform=macOS' \
     -archivePath "$ARCHIVE" archive "${SETTINGS[@]}" > build/archive.log 2>&1; then
  grep -E "error:" build/archive.log | sort -u | head -50 >&2 || true
  tail -40 build/archive.log >&2
  fail "archive failed (full log: build/archive.log)"
fi
grep -E "warning:" build/archive.log | grep -v "/Vendor/" | sort -u | head -40 || true

# 4. Export the app.
step "Export"
rm -rf dist/Zipper.app build/export
if [[ -n "$SIGN" ]]; then
  OPTIONS=build/ExportOptions.plist
  cp Packaging/ExportOptions.plist "$OPTIONS"
  /usr/libexec/PlistBuddy -c "Set :teamID $TEAM" "$OPTIONS"
  if ! xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTIONS" -exportPath build/export > build/export.log 2>&1; then
    tail -40 build/export.log >&2
    fail "export failed (full log: build/export.log)"
  fi
  ditto build/export/Zipper.app dist/Zipper.app
else
  # Developer ID export needs the certificate; an ad-hoc build is copied out of the archive as is.
  ditto "$ARCHIVE/Products/Applications/Zipper.app" dist/Zipper.app
fi
APP=dist/Zipper.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")

# 5. Check the app before packaging it.
step "Check the app ($VERSION, build $BUILD)"
codesign --verify --deep --strict --verbose=2 "$APP"
plutil -lint "$APP/Contents/Info.plist"
BINARIES=("$APP/Contents/MacOS/Zipper" "$APP/Contents/PlugIns/ZipperQuickLook.appex/Contents/MacOS/ZipperQuickLook")
for helper in "$APP/Contents/Helpers/"*; do BINARIES+=("$helper"); done
for bin in "${BINARIES[@]}"; do
  [[ -f "$bin" ]] || fail "missing $bin"
  lipo "$bin" -verify_arch arm64 x86_64 || fail "$(basename "$bin") isn't universal (has: $(lipo -archs "$bin"))"
  echo "$(basename "$bin"): $(lipo -archs "$bin")"
done
[[ -x "$APP/Contents/Helpers/7zz" ]] || fail "7-Zip isn't bundled"
"$APP/Contents/Helpers/zipper" --version

# 6. Notarize the app, so the copy inside the DMG is stapled too.
if [[ $NOTARIZE == 1 ]]; then
  step "Notarize the app"
  Scripts/notarize.sh "$APP"
fi

# 7. Disk image.
step "Disk image"
if [[ -n "$SIGN" ]]; then Scripts/make-dmg.sh "$APP" --sign "$SIGN"; else Scripts/make-dmg.sh "$APP"; fi
DMG="dist/Zipper-$VERSION.dmg"
[[ -f "$DMG" ]] || fail "no $DMG"
if [[ $NOTARIZE == 1 ]]; then
  step "Notarize the disk image"
  Scripts/notarize.sh "$DMG"
fi

# 8. Check the disk image the way a user gets it.
step "Check the disk image"
hdiutil verify "$DMG"
MOUNT=$(mktemp -d)
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$DMG" >/dev/null
trap 'hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true' EXIT
[[ -d "$MOUNT/Zipper.app" ]] || fail "the DMG has no Zipper.app"
[[ -L "$MOUNT/Applications" ]] || fail "the DMG has no Applications shortcut"
codesign --verify --deep --strict "$MOUNT/Zipper.app"
hdiutil detach "$MOUNT" >/dev/null
trap - EXIT
if [[ $NOTARIZE == 1 ]]; then
  spctl --assess --type execute --verbose "$APP"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
fi

(cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
step "Done"
if [[ $NOTARIZE == 1 ]]; then STATE="signed with $SIGN, notarized and stapled"
elif [[ -n "$SIGN" ]]; then STATE="signed with $SIGN, not notarized"
else STATE="ad-hoc signed (testing only: Gatekeeper blocks it on other Macs until it's notarized)"; fi
echo "$DMG — $STATE"
cat "$DMG.sha256"
