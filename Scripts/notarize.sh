#!/usr/bin/env bash
# Submits the DMG to Apple's notary service and staples the ticket.
# Requires a Developer ID certificate and an App Store Connect API key or app-specific password
# stored with:  xcrun notarytool store-credentials "UA_NOTARY" --apple-id ... --team-id ...
#
#   Scripts/notarize.sh dist/UniversalArchiver-0.1.0.dmg
#
# Nothing in this repository has been notarized: no Developer ID credentials were available when it
# was built. Run this yourself after Scripts/build-app.sh --sign ... and Scripts/make-dmg.sh --sign ...
set -euo pipefail
DMG="$1"
PROFILE="${NOTARY_PROFILE:-UA_NOTARY}"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
echo "Notarized and stapled: $DMG"
