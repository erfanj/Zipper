#!/usr/bin/env bash
# Runs a built Zipper.app the way a user would and fails if it doesn't work:
#   * the embedded `zipper` tool and the bundled 7-Zip round-trip an encrypted 7z (a wrong password
#     must fail), and every engine the app bundles reports itself usable;
#   * the Intel slice runs too, when Rosetta is installed;
#   * the app launches, stays up, opens an archive, and quits without a crash report.
# Screenshots go to $SCREENSHOT_DIR (default dist/screenshots). They're best effort: screen capture
# needs the Screen Recording permission, which a Mac may not grant to Terminal or CI.
#
#   Scripts/smoke-test-app.sh [dist/Zipper.app]
set -euo pipefail
APP="${1:-dist/Zipper.app}"
SHOTS="${SCREENSHOT_DIR:-dist/screenshots}"
CLI="$APP/Contents/Helpers/zipper"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Contents/Info.plist")
WORK=$(mktemp -d)
mkdir -p "$SHOTS"
fail() { echo "error: $*" >&2; exit 1; }
quit_app() { osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || pkill -x Zipper || true; }
trap 'quit_app; rm -rf "$WORK"' EXIT

echo "==> Command-line tool and bundled engines"
"$CLI" --version
"$CLI" engines --json | /usr/bin/python3 -c '
import json, sys
engines = {e["id"]: e for e in json.load(sys.stdin)}
for required in ("libarchive", "7zip"):
    e = engines.get(required) or {}
    if not e.get("isAvailable"):
        sys.exit("{} is not usable: {}".format(required, e.get("unavailableReason")))
    print("{} {}: usable".format(e["name"], e.get("version") or ""))'
mkdir -p "$WORK/Sample/Documents"
echo "Hello from Zipper" > "$WORK/Sample/Documents/Read me.txt"
head -c 300000 /dev/urandom > "$WORK/Sample/data.bin"
PASSWORD='pässwörd 🔑'
printf '%s\n' "$PASSWORD" | "$CLI" compress "$WORK/Sample" -o "$WORK/Sample.7z" --encrypt aes256 --hide-names --password-stdin
printf '%s\n' "$PASSWORD" | "$CLI" extract "$WORK/Sample.7z" -o "$WORK/out" --password-stdin --verify
diff -r "$WORK/Sample" "$WORK/out/Sample" || fail "the extracted files differ from the originals"
if printf 'wrong\n' | "$CLI" test "$WORK/Sample.7z" --password-stdin >/dev/null 2>&1; then fail "a wrong password was accepted"; fi
echo "Encrypted 7z round trip: OK"

if /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
  echo "==> Intel slice (Rosetta)"
  /usr/bin/arch -x86_64 "$CLI" --version
  /usr/bin/arch -x86_64 "$CLI" test "$WORK/Sample.7z" --password-stdin <<<"$PASSWORD"
else
  echo "==> Intel slice: skipped (Rosetta isn't installed)"
fi

shot() {
  local file="$SHOTS/$1.png"
  if screencapture -x "$file" 2>/dev/null && [[ -s "$file" ]]; then echo "Screenshot: $file"; else echo "Screenshot $1: unavailable"; fi
}

echo "==> The app"
REPORTS="$HOME/Library/Logs/DiagnosticReports"
mkdir -p "$REPORTS"
MARK="$WORK/start"; touch "$MARK"
quit_app; sleep 1
open -n "$APP"
for _ in $(seq 1 30); do pgrep -x Zipper >/dev/null && break; sleep 1; done
pgrep -x Zipper >/dev/null || fail "Zipper didn't start"
sleep 6
pgrep -x Zipper >/dev/null || fail "Zipper quit right after launch"
shot home
ditto -c -k --keepParent "$WORK/Sample" "$WORK/Sample.zip"
open -a "$APP" "$WORK/Sample.zip"
sleep 6
pgrep -x Zipper >/dev/null || fail "Zipper quit after opening an archive"
shot browser
quit_app
for _ in $(seq 1 15); do pgrep -x Zipper >/dev/null || break; sleep 1; done
CRASH=$(find "$REPORTS" -newer "$MARK" -name 'Zipper*' 2>/dev/null | head -1)
if [[ -n "$CRASH" ]]; then head -60 "$CRASH" >&2; fail "Zipper crashed: $CRASH"; fi
echo "Launched, opened an archive and quit cleanly."
