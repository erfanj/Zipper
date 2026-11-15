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
run() {
  local name="$1" log="$OUT/$2"
  shift 2
  printf '==> %s\n' "$name"
  local started=$SECONDS
  if "$@" > "$log" 2>&1; then
    printf 'PASS  %s (%ss)\n' "$name" "$((SECONDS - started))" | tee -a "$REPORT"
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL  %s (%ss) — see %s\n' "$name" "$((SECONDS - started))" "$log" | tee -a "$REPORT"
  fi
}
note() { printf '      %s\n' "$*" >> "$REPORT"; }

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
  export UA_HELPERS_DIR="$PWD/Vendor/macos/helpers"
  swift build --build-tests && swift test --skip-build
}
ui_tests() {
  xcodebuild test -project Zipper.xcodeproj -scheme Zipper -destination 'platform=macOS' \
    -derivedDataPath build/DerivedData -resultBundlePath "$OUT/UITests.xcresult"
}

run "Toolchain" toolchain.log toolchain
note "$(head -1 "$OUT/toolchain.log" 2>/dev/null)"
run "Pinned libraries and 7-Zip" dependencies.log dependencies
run "Xcode project" project.log project
run "App build (Debug)" build.log build_app
note "compiler warnings outside Vendor: $(grep -E 'warning:' "$OUT/build.log" 2>/dev/null | grep -v '/Vendor/' | sort -u | wc -l | tr -d ' ')"
grep -E 'error:' "$OUT/build.log" 2>/dev/null | sort -u | head -40 > "$OUT/build-errors.txt"
run "App bundle (signature, helpers, Quick Look extension)" bundle.log check_bundle
run "Package tests on macOS" package-tests.log package_tests
note "$(grep -E 'Executed [0-9]+ tests' "$OUT/package-tests.log" 2>/dev/null | tail -1 | sed 's/^[[:space:]]*//')"
grep -E 'error:|Test Case .* failed' "$OUT/package-tests.log" 2>/dev/null | head -80 > "$OUT/package-test-failures.txt"
run "UI tests (XCUITest)" ui-tests.log ui_tests
note "$(grep -E 'Executed [0-9]+ tests' "$OUT/ui-tests.log" 2>/dev/null | tail -1 | sed 's/^[[:space:]]*//')"
grep -E 'error:|Test Case .* failed' "$OUT/ui-tests.log" 2>/dev/null | head -80 > "$OUT/ui-test-failures.txt"

if [[ $DMG == 1 ]]; then
  run "Release DMG (universal, ad-hoc signed)" release.log Scripts/release.sh
  note "$(ls dist/Zipper-*.dmg 2>/dev/null | tail -1)"
  run "Smoke test of the release app" smoke-test.log Scripts/smoke-test-app.sh dist/Zipper.app
fi

{
  echo
  if [[ $FAILED == 0 ]]; then echo "All steps passed."; else echo "$FAILED step(s) failed."; fi
} | tee -a "$REPORT"
echo "Report: $REPORT"
[[ $FAILED == 0 ]]
