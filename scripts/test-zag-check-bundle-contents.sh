#!/bin/bash
# Regression tests for scripts/zag-check-bundle-contents.sh.
# Usage: bash scripts/test-zag-check-bundle-contents.sh
set -euo pipefail

GUARD="$(cd "$(dirname "$0")" && pwd)/zag-check-bundle-contents.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-bundle-guard.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
FAILURES=0

make_app() {
	local app="$WORK/$1/Payload/Feather.app"
	mkdir -p "$app/Frameworks/OpenSSL.framework" "$app/en.lproj"
	touch "$app/Feather" "$app/Info.plist" "$app/Assets.car" "$app/en.lproj/Localizable.strings" \
		"$app/Frameworks/OpenSSL.framework/OpenSSL" "$app/ZagSplashCinematic.mp4" "$app/ellekit.deb"
	echo "$app"
}

expect() {
	local want="$1" label="$2" target="$3" status=0
	bash "$GUARD" "$target" >/dev/null 2>&1 || status=$?
	if [[ "$status" == "$want" ]]; then
		echo "PASS  $label"
	else
		echo "FAIL  $label (expected exit $want, got $status)"
		FAILURES=$((FAILURES + 1))
	fi
}

clean=$(make_app clean)
expect 0 "clean app passes" "$clean"
(cd "$WORK/clean" && zip -qr clean.ipa Payload)
expect 0 "clean ipa passes" "$WORK/clean/clean.ipa"

for leak in \
	"SettingsView.swift.avatar-move-20261015-065434.backup" \
	"ZagSelfUpdateStatusView.swift.before-reopen-guidance-20261015-043420" \
	"ZagSelfUpdateSignatureDiagnosticsView.swift.cms-v1-backup" \
	"FR.swift.before-cleanup" \
	"ZsignHandler.swift.before-restore" \
	"Feather.xcconfig" \
	"LeakedSource.swift" \
	"Frameworks/OpenSSL.framework/Notes.BACKUP" \
	"server.pem" \
	"identity.p12"; do
	name=$(echo "$leak" | tr '/.' '__')
	app=$(make_app "$name")
	mkdir -p "$(dirname "$app/$leak")"
	touch "$app/$leak"
	expect 1 "rejects app with $leak" "$app"
	(cd "$WORK/$name" && zip -qr leak.ipa Payload)
	expect 1 "rejects ipa with $leak" "$WORK/$name/leak.ipa"
done

expect 2 "missing target is a usage error" "$WORK/does-not-exist"

# First-launch test builds (reporting compiled on) are never releasable.
marked=$(make_app marked)
printf 'binary\0ZAG-FIRST-LAUNCH-TEST-BUILD-NOT-FOR-RELEASE\0more' > "$marked/Feather"
expect 1 "rejects a first-launch test build (app)" "$marked"
(cd "$WORK/marked" && zip -qr marked.ipa Payload)
expect 1 "rejects a first-launch test build (ipa)" "$WORK/marked/marked.ipa"
status=0; ZAG_ALLOW_FIRST_LAUNCH_TEST_BUILD=1 bash "$GUARD" "$WORK/marked/marked.ipa" >/dev/null 2>&1 || status=$?
if [[ "$status" == 0 ]]; then echo "PASS  explicit override for the approved acceptance"; else echo "FAIL  override (exit $status)"; FAILURES=$((FAILURES + 1)); fi
status=0; ZAG_ALLOW_FIRST_LAUNCH_TEST_BUILD=yes bash "$GUARD" "$WORK/marked/marked.ipa" >/dev/null 2>&1 || status=$?
if [[ "$status" == 1 ]]; then echo "PASS  only the exact override value is accepted"; else echo "FAIL  loose override (exit $status)"; FAILURES=$((FAILURES + 1)); fi

if (( FAILURES > 0 )); then
	echo "$FAILURES test(s) failed"
	exit 1
fi
echo "All bundle guard tests passed"
