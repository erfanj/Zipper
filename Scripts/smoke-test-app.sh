#!/usr/bin/env bash
# Runs a built Zipper.app the way a user would and fails if it doesn't work:
#   * the embedded `zipper` tool and the bundled 7-Zip round-trip an encrypted 7z, a wrong password
#     is rejected as a wrong password, and the engines the app bundles report themselves usable;
#   * the Intel slice runs too, when Rosetta is installed;
#   * the app launches, opens an archive (the app itself reports the result), quits when asked and
#     exits cleanly.
# Screenshots go to $SCREENSHOT_DIR (default dist/screenshots). They're best effort: screen capture
# needs the Screen Recording permission, which a Mac may not grant to Terminal or CI.
#
#   Scripts/smoke-test-app.sh [dist/Zipper.app]
set -euo pipefail
APP="${1:-dist/Zipper.app}"
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"   # `open -a` needs an absolute path
SHOTS="${SCREENSHOT_DIR:-dist/screenshots}"
CLI="$APP/Contents/Helpers/zipper"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Contents/Info.plist")
WORK=$(mktemp -d)
APP_PID=""
mkdir -p "$SHOTS"
fail() { echo "error: $*" >&2; exit 1; }
cleanup() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then kill -9 "$APP_PID" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

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
"$CLI" test "$WORK/Sample.7z" --password-stdin <<<"$PASSWORD" >/dev/null || fail "testing with the right password failed"
rc=0
"$CLI" test "$WORK/Sample.7z" --password-stdin <<<'wrong' >/dev/null 2>&1 || rc=$?
[[ $rc == 3 ]] || fail "a wrong password should exit with 3 (password), not $rc"
echo "Encrypted 7z round trip: OK"

if /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
  echo "==> Intel slice (Rosetta)"
  /usr/bin/arch -x86_64 "$CLI" --version
  /usr/bin/arch -x86_64 "$CLI" test "$WORK/Sample.7z" --password-stdin <<<"$PASSWORD" >/dev/null || fail "the Intel slice failed to test the archive"
  echo "Intel slice: OK"
else
  echo "==> Intel slice: skipped (Rosetta isn't installed)"
fi

shot() {
  local file="$SHOTS/$1.png"
  if screencapture -x "$file" 2>/dev/null && [[ -s "$file" ]]; then echo "Screenshot: $file"; else echo "Screenshot $1: unavailable"; fi
}

echo "==> The app"
pkill -x Zipper 2>/dev/null || true
sleep 1
REPORT="$WORK/opened.txt"
# Launched directly rather than with `open`, so this script knows the process, its exit status and
# output, and can pass ZIPPER_SMOKE_REPORT. Documents opened later still reach this instance.
ZIPPER_SMOKE_REPORT="$REPORT" "$APP/Contents/MacOS/Zipper" > "$WORK/app.log" 2>&1 &
APP_PID=$!
alive() { kill -0 "$APP_PID" 2>/dev/null; }
died() {
  local status=0
  wait "$APP_PID" || status=$?
  tail -40 "$WORK/app.log" >&2 || true
  fail "Zipper $1 (exit status $status)"
}
sleep 8
alive || died "quit right after launch"
open -a "$APP"   # bring it to the front, as a Finder launch would
sleep 2
shot home

ditto -c -k --norsrc --noextattr --keepParent "$WORK/Sample" "$WORK/Sample.zip"
open -a "$APP" "$WORK/Sample.zip"
for _ in $(seq 1 30); do
  [[ -s "$REPORT" ]] && break
  alive || break
  sleep 1
done
alive || died "quit after being asked to open an archive"
grep -q '^opened Sample.zip ' "$REPORT" 2>/dev/null || fail "the app didn't open Sample.zip ($(cat "$REPORT" 2>/dev/null || echo 'no report'))"
echo "Opened in the app: $(head -1 "$REPORT")"
sleep 2
shot browser

# Quit like the menu does. Without Automation permission (common on CI) fall back to SIGTERM.
QUIT="the Quit command"
if ! osascript -e 'with timeout of 30 seconds' -e "tell application id \"$BUNDLE_ID\" to quit" -e 'end timeout' > /dev/null 2> "$WORK/osascript.log"; then
  QUIT="SIGTERM"
  echo "Couldn't send the Quit command ($(tr '\n' ' ' < "$WORK/osascript.log")); sending SIGTERM instead."
  kill -TERM "$APP_PID" 2>/dev/null || true
fi
for _ in $(seq 1 20); do
  alive || break
  sleep 1
done
alive && fail "Zipper didn't quit within 20 seconds of $QUIT"
STATUS=0
wait "$APP_PID" || STATUS=$?
APP_PID=""
if [[ $STATUS != 0 && ! ( $QUIT == SIGTERM && $STATUS == 143 ) ]]; then
  tail -40 "$WORK/app.log" >&2 || true
  fail "Zipper exited with status $STATUS after $QUIT"
fi
echo "Launched, opened an archive, and quit cleanly after $QUIT."
