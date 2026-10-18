#!/usr/bin/env bash
# Submits Zipper to Apple's notary service, waits for the verdict and staples the ticket.
#
# One-time setup (an app-specific password from appleid.apple.com, or an App Store Connect API key):
#   xcrun notarytool store-credentials "ZIPPER_NOTARY" --apple-id you@example.com --team-id TEAMID
#
#   Scripts/notarize.sh dist/Zipper.app          # zips, submits, staples the app itself
#   Scripts/notarize.sh dist/Zipper-1.0.0.dmg    # submits and staples the disk image
#
# Notarize the app first, then build the DMG from the stapled app and notarize the DMG too: both
# then open without a network connection to Apple.
set -euo pipefail
TARGET="${1:?Usage: Scripts/notarize.sh dist/Zipper.app | dist/Zipper-<version>.dmg}"
PROFILE="${NOTARY_PROFILE:-ZIPPER_NOTARY}"
SUBMIT="$TARGET"
if [[ "$TARGET" == *.app ]]; then
  SUBMIT="$(mktemp -d)/$(basename "$TARGET" .app).zip"
  ditto -c -k --keepParent "$TARGET" "$SUBMIT"   # the notary service takes zips, DMGs and pkgs
fi
OUT=$(xcrun notarytool submit "$SUBMIT" --keychain-profile "$PROFILE" --wait 2>&1 | tee /dev/stderr)
if ! grep -q "status: Accepted" <<<"$OUT"; then
  ID=$(grep -m1 -E "^\s*id:" <<<"$OUT" | awk '{print $2}')
  echo "Notarization failed. Apple's log explains why:" >&2
  [[ -n "$ID" ]] && xcrun notarytool log "$ID" --keychain-profile "$PROFILE" >&2
  exit 1
fi
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"
if [[ "$TARGET" == *.app ]]; then
  spctl --assess --type execute --verbose "$TARGET"
else
  spctl --assess --type open --context context:primary-signature --verbose "$TARGET"
fi
echo "Notarized and stapled: $TARGET"
