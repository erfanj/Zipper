#!/usr/bin/env bash
# Everything the macOS CI job and the release workflow do, on your own Mac, in one command. Use it
# when GitHub Actions isn't available. Each step runs even if an earlier one failed, and the result
# of each is written to build/mac-check/REPORT.txt with the logs next to it.
#
#   Scripts/mac-check.sh            # app build, bundle check, package tests, UI tests
#   Scripts/mac-check.sh --dmg      # the same, then the release DMG and its smoke test
#
# Needs Xcode 16 or later and Homebrew (for XcodeGen). The first run builds the pinned C libraries
# and 7-Zip (a few minutes). The UI tests take over the keyboard and mouse for a few minutes and
# need Xcode to be allowed to control the Mac (macOS asks the first time).
#
# Xcode only has to be installed and its licence accepted (sudo xcodebuild -license). If the Mac's
# active developer directory is still the Command Line Tools, the Xcode in /Applications is used for
# this run without changing the system setting.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

DMG=0
for arg in "$@"; do
  case "$arg" in
    --dmg) DMG=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done
if [[ "$(uname -s)" != "Darwin" ]]; then echo "This script is for macOS." >&2; exit 2; fi

OUT=build/mac-check
rm -rf "$OUT"
mkdir -p "$OUT"
REPORT="$OUT/REPORT.txt"
FAILED=0
{
  echo "Zipper Mac check, $(date '+%Y-%m-%d %H:%M')"
  echo "Commit: $(git rev-parse --short HEAD 2>/dev/null) on $(git branch --show-current 2>/dev/null)"
  echo "macOS $(sw_vers -productVersion), $(uname -m), $(sysctl -n hw.memsize | awk '{printf "%.0f GB", $1 / 1073741824}')"
  echo
} > "$REPORT"

# run NAME LOGFILE COMMAND…: runs the command, records PASS or FAIL, never stops the script.
# OK tells the caller how the step went.
OK=0
run() {
  local name="$1" log="$OUT/$2"
  shift 2
  printf '==> %s\n' "$name"
  local started=$SECONDS
  if "$@" > "$log" 2>&1; then
    OK=1
    printf 'PASS  %s (%ss)\n' "$name" "$((SECONDS - started))" | tee -a "$REPORT"
  else
    OK=0
    FAILED=$((FAILED + 1))
    printf 'FAIL  %s (%ss) — see %s\n' "$name" "$((SECONDS - started))" "$log" | tee -a "$REPORT"
  fi
}
# note TEXT: a detail line under the last step; nothing when there is no text.
note() { [[ -n "${1//[[:space:]]/}" ]] && printf '      %s\n' "$*" >> "$REPORT"; return 0; }
finish() {
  {
    echo
    if [[ $FAILED == 0 ]]; then echo "All steps passed."; else echo "$FAILED step(s) failed."; fi
  } | tee -a "$REPORT"
  echo "Report: $REPORT"
  [[ $FAILED == 0 ]]
}

# A Mac where Xcode was installed after the Command Line Tools still points at the tools, and then
# xcodebuild refuses to run. Use the installed Xcode for this run; DEVELOPER_DIR reaches every
# script started from here and leaves the system setting alone.
if ! xcodebuild -version > /dev/null 2>&1 && [[ -z "${DEVELOPER_DIR:-}" ]]; then
  for xcode in /Applications/Xcode.app /Applications/Xcode*.app; do
    if [[ -x "$xcode/Contents/Developer/usr/bin/xcodebuild" ]]; then
      export DEVELOPER_DIR="$xcode/Contents/Developer"
      break
    fi
  done
fi

toolchain() { xcodebuild -version && swift --version; }
dependencies() {
  [[ -d Vendor/macos/xcframeworks/CArchive.xcframework && -x Vendor/macos/helpers/7zz ]] && { echo "already built"; return 0; }
  Scripts/build-deps-macos.sh
}
project() {
  command -v xcodegen > /dev/null || brew install xcodegen
  xcodegen generate
}
build_app() {
  xcodebuild -project Zipper.xcodeproj -scheme Zipper -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath build/DerivedData build
}
check_bundle() {
  local app=build/DerivedData/Build/Products/Debug/Zipper.app
  codesign --verify --deep --strict --verbose=2 "$app" && ls -la "$app/Contents/Helpers" "$app/Contents/PlugIns" \
    && "$app/Contents/Helpers/zipper" --version && plutil -lint "$app/Contents/Info.plist"
}
package_tests() {
  # Set for these two commands only: the app honours UA_HELPERS_DIR too, and exported it would let
  # the UI tests and the smoke test find 7-Zip here when the app bundle has none.
  swift build --build-tests && UA_HELPERS_DIR="$PWD/Vendor/macos/helpers" swift test --skip-build
}
ui_tests() {
  xcodebuild test -project Zipper.xcodeproj -scheme Zipper -destination 'platform=macOS' \
    -derivedDataPath build/DerivedData -resultBundlePath "$OUT/UITests.xcresult"
}

run "Toolchain" toolchain.log toolchain
note "$(head -1 "$OUT/toolchain.log" 2>/dev/null)"
[[ -n "${DEVELOPER_DIR:-}" ]] && note "using DEVELOPER_DIR=$DEVELOPER_DIR"
if [[ $OK == 0 ]]; then
  # Every later step needs xcodebuild; without it they would spend ten minutes failing one by one.
  if grep -qi 'license' "$OUT/toolchain.log"; then
    note "Xcode's licence hasn't been accepted. Run \"sudo xcodebuild -license\", then this script again."
  else
    note "Xcode 16 or later is needed. Install it from the App Store, open it once, then run this script again."
  fi
  note "Nothing else was run."
  finish
  exit 1
fi
run "Pinned libraries and 7-Zip" dependencies.log dependencies
run "Xcode project" project.log project
run "App build (Debug)" build.log build_app
# Not counted: Xcode's App Intents step saying that the Quick Look extension has no Shortcuts actions
# ("Metadata extraction skipped"). It is a remark from a build tool, not about the code; the app's own
# actions are extracted (Zipper.app/Contents/Resources/Metadata.appintents).
[[ $OK == 1 ]] && note "compiler warnings outside Vendor: $(grep -E 'warning:' "$OUT/build.log" 2>/dev/null | grep -v -e '/Vendor/' -e 'appintentsmetadataprocessor' | sort -u | wc -l | tr -d ' ')"
grep -E 'error:' "$OUT/build.log" 2>/dev/null | sort -u | head -40 > "$OUT/build-errors.txt"
run "App bundle (signature, helpers, Quick Look extension)" bundle.log check_bundle
run "Package tests on macOS" package-tests.log package_tests
# swift test runs each test bundle on its own and prints a total for each: add them up.
note "$(awk "/Test Suite 'All tests'/ { getline; tests += \$2; for (i = 3; i <= NF; i++) { if (\$i ~ /^skipped/) skipped += \$(i - 2); if (\$i ~ /^failures?/) failed += \$(i - 1) } }
  END { if (tests) printf \"%d tests, %d skipped, %d failures\", tests, skipped, failed }" "$OUT/package-tests.log" 2>/dev/null)"
grep -E 'error:|Test Case .* failed' "$OUT/package-tests.log" 2>/dev/null | head -80 > "$OUT/package-test-failures.txt"
run "UI tests (XCUITest)" ui-tests.log ui_tests
note "$(grep -E 'Executed [0-9]+ tests' "$OUT/ui-tests.log" 2>/dev/null | tail -1 | sed 's/^[[:space:]]*//')"
grep -E 'error:|Test Case .* failed' "$OUT/ui-tests.log" 2>/dev/null | head -80 > "$OUT/ui-test-failures.txt"

if [[ $DMG == 1 ]]; then
  # A DMG or app left by an earlier run must not be mistaken for this one's.
  rm -rf dist/Zipper.app dist/Zipper-*.dmg dist/Zipper-*.dmg.sha256
  run "Release DMG (universal, ad-hoc signed)" release.log Scripts/release.sh
  note "$(ls dist/Zipper-*.dmg 2>/dev/null | tail -1)"
  if [[ $OK == 1 ]]; then
    run "Smoke test of the release app" smoke-test.log Scripts/smoke-test-app.sh dist/Zipper.app
  else
    FAILED=$((FAILED + 1))
    echo "SKIP  Smoke test of the release app — there is no release app to test" | tee -a "$REPORT"
  fi
fi

finish
