#!/usr/bin/env bash
# Submits Zipper to Apple's notary service, waits for the verdict and staples the ticket.
#
# Credentials, either:
#   * a keychain profile, stored once (an app-specific password from account.apple.com):
#       xcrun notarytool store-credentials "ZIPPER_NOTARY" --apple-id you@example.com --team-id TEAMID
#     (NOTARY_PROFILE selects another profile name), or
#   * an App Store Connect API key, as CI uses: NOTARY_KEY_PATH (the AuthKey_….p8 file),
#     NOTARY_KEY_ID and NOTARY_ISSUER. Use a team key: individual keys (no issuer) need the
#     notarytool in Xcode 26 or later.
#
#   Scripts/notarize.sh dist/Zipper.app          # zips, submits, staples the app itself
#   Scripts/notarize.sh dist/Zipper-1.0.0.dmg    # submits and staples the disk image
#
# Notarize the app first, then build the DMG from the stapled app and notarize the DMG too: both
# then open without a network connection to Apple.
set -euo pipefail
TARGET="${1:?Usage: Scripts/notarize.sh dist/Zipper.app | dist/Zipper-<version>.dmg}"
if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
  AUTH=(--key "$NOTARY_KEY_PATH" --key-id "${NOTARY_KEY_ID:?NOTARY_KEY_ID is required with NOTARY_KEY_PATH}")
  if [[ -n "${NOTARY_ISSUER:-}" ]]; then
    AUTH+=(--issuer "$NOTARY_ISSUER")
  elif (( $(xcodebuild -version | awk 'NR==1 { print int($2) }') < 26 )); then
    echo "NOTARY_ISSUER is required: this Xcode's notarytool only accepts team API keys (individual keys need Xcode 26)." >&2
    exit 2
  fi
else
  AUTH=(--keychain-profile "${NOTARY_PROFILE:-ZIPPER_NOTARY}")
fi
SUBMIT="$TARGET"
if [[ "$TARGET" == *.app ]]; then
  SUBMIT="$(mktemp -d)/$(basename "$TARGET" .app).zip"
  ditto -c -k --keepParent "$TARGET" "$SUBMIT"   # the notary service takes zips, DMGs and pkgs
fi
OUT=$(xcrun notarytool submit "$SUBMIT" "${AUTH[@]}" --wait --timeout 1h 2>&1 | tee /dev/stderr) || true
if ! grep -q "status: Accepted" <<<"$OUT"; then
  ID=$(grep -m1 -E "^\s*id:" <<<"$OUT" | awk '{print $2}')
  echo "Notarization failed. Apple's log explains why:" >&2
  [[ -n "$ID" ]] && xcrun notarytool log "$ID" "${AUTH[@]}" >&2
  exit 1
fi
# The ticket can take a moment to become available after "Accepted"; retry before giving up.
for attempt in 1 2 3 4 5; do
  xcrun stapler staple "$TARGET" && break
  [[ $attempt == 5 ]] && { echo "Stapling failed although notarization was accepted." >&2; exit 1; }
  sleep $((attempt * 15))
done
xcrun stapler validate "$TARGET"
if [[ "$TARGET" == *.app ]]; then
  spctl --assess --type execute --verbose "$TARGET"
else
  spctl --assess --type open --context context:primary-signature --verbose "$TARGET"
fi
echo "Notarized and stapled: $TARGET"
