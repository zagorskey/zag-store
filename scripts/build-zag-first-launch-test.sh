#!/bin/bash
# TEST-ONLY build for the first-launch preview acceptance (website repository:
# ops/first-launch-analytics/ACCEPTANCE-REPORTER.md). It compiles the Release configuration
# with the condition ZAG_FIRST_LAUNCH_TEST_BUILD: first-launch reporting is compiled on, and
# the one-time disclosure still asks for consent before anything is stored or sent.
#
# Output: an UNSIGNED .app only. Nothing is packaged, signed or published. Turning it into an
# IPA needs separate approval; zag-check-bundle-contents.sh, and so publish-zag-release.zsh,
# refuses any bundle built here (it carries ZagFirstLaunchReporter.testBuildMarker).
# Normal builds are unaffected: the condition is set only on this command line, and the app is
# installed into the output folder (DSTROOT), never into the checkout's _build/, which
# ZagStore-Package.zsh packages. The script fails if _build/ changes.
#
# Usage: scripts/build-zag-first-launch-test.sh [output folder]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-"${TMPDIR:-/tmp/}ZagStore-first-launch-test"}
MARKER=ZAG-FIRST-LAUNCH-TEST-BUILD-NOT-FOR-RELEASE
SHARED="$ROOT/_build/Applications/Feather.app"
shared_state() { if [[ -e "$SHARED/Feather" ]]; then shasum -a 256 "$SHARED/Feather"; else echo absent; fi; }
BEFORE=$(shared_state)
cd "$ROOT"
xcodebuild -project Feather.xcodeproj -scheme Feather -configuration Release \
	-destination generic/platform=iOS -derivedDataPath "$OUT/DerivedData" \
	CODE_SIGNING_ALLOWED=NO DSTROOT="$OUT/dstroot" \
	SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) ZAG_FIRST_LAUNCH_TEST_BUILD' \
	build > "$OUT.build.log" 2>&1 || { tail -30 "$OUT.build.log"; echo "Build failed (log: $OUT.build.log)"; exit 1; }
[[ "$(shared_state)" == "$BEFORE" ]] || { echo "REFUSING: the build changed $SHARED; rebuild normally before packaging"; exit 1; }
APP="$OUT/dstroot/Applications/Feather.app"
[[ -d "$APP" && ! -L "$APP" ]] || { echo "No .app produced at $APP"; exit 1; }
EXE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")
grep -qaF "$MARKER" "$APP/$EXE" || { echo "Test marker missing from $APP/$EXE"; exit 1; }
if bash "$ROOT/scripts/zag-check-bundle-contents.sh" "$APP" >/dev/null 2>&1; then
	echo "The release bundle check accepted a test build"; exit 1
fi
echo "Test-only build (first-launch reporting ON, consent required, unsigned, not for release):"
echo "  $APP"
