#!/bin/bash
# Regression checks for the first-launch reporter (off by default).
# Usage: bash scripts/test-zag-first-launch-report.sh
# With ZAG_WEBSITE_REPO set to the website checkout, the request body built
# here is also parsed by the server endpoint's own validator.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/Feather/Utilities/ZagFirstLaunchReport.swift"
REPORTER="$ROOT/Feather/Utilities/ZagFirstLaunchReporter.swift"
APP="$ROOT/Feather/FeatherApp.swift"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-first-launch-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
FAILURES=0

check() {
	local label="$1"; shift
	if "$@"; then echo "PASS  $label"; else echo "FAIL  $label"; FAILURES=$((FAILURES + 1)); fi
}

finish_body=$(awk '/func finish\(\)/ { inside = 1 } inside { print } inside && /^    }$/ { exit }' "$APP")
hook_after_interactive() {
	local interactive hook
	interactive=$(grep -n 'markInteractive()' <<< "$finish_body" | head -1 | cut -d: -f1)
	hook=$(grep -n 'ZagFirstLaunchReporter.launchBecameInteractive()' <<< "$finish_body" | head -1 | cut -d: -f1)
	[[ -n "$interactive" && -n "$hook" && "$interactive" -lt "$hook" ]]
}
# Release default: off. Only the test-only build's compilation condition turns it on, and
# nothing in the project or xcconfig sets that condition.
flag_branches() {
	[[ "$(grep -c 'static let featureEnabled' "$REPORTER")" == 2 ]] &&
	awk '/^#if ZAG_FIRST_LAUNCH_TEST_BUILD$/ {s=1; next} /^#else$/ && s==1 {s=2; next} /^#endif$/ {s=0}
		s==1 && /static let featureEnabled = true$/ {on=1} s==2 && /static let featureEnabled = false$/ {off=1}
		END {exit !(on && off)}' "$REPORTER"
}
check "feature is compiled off except in the test-only build" flag_branches
check "no project setting enables the test-only build" \
	bash -c "! grep -rq 'ZAG_FIRST_LAUNCH_TEST_BUILD' '$ROOT/Feather.xcodeproj' '$ROOT'/*.xcconfig '$ROOT/Feather' --exclude=ZagFirstLaunchReporter.swift"
check "the test-only build is made only by its script, unsigned, no IPA" \
	bash -c "grep -q \"SWIFT_ACTIVE_COMPILATION_CONDITIONS='\\\$(inherited) ZAG_FIRST_LAUNCH_TEST_BUILD'\" '$ROOT/scripts/build-zag-first-launch-test.sh' && grep -q 'CODE_SIGNING_ALLOWED=NO' '$ROOT/scripts/build-zag-first-launch-test.sh' && ! grep -qiE 'zip|\\.ipa|codesign |exportArchive' '$ROOT/scripts/build-zag-first-launch-test.sh'"
consent_gate_unchanged() {
	# The flag changes featureEnabled and the marker only; the consent gate is shared.
	grep -q 'featureEnabled && UserDefaults.standard.bool(forKey: consentKey)' "$REPORTER" &&
	[[ "$(grep -c '^#if ZAG_FIRST_LAUNCH_TEST_BUILD$' "$REPORTER")" == 1 ]] &&
	! grep -n 'ZAG_FIRST_LAUNCH_TEST_BUILD' "$REPORTER" | grep -vE '^[0-9]+:(#if ZAG_FIRST_LAUNCH_TEST_BUILD$|[[:space:]]*///)' | grep -q .
}
check "the test-only build still requires consent (same gate)" consent_gate_unchanged
check "the test-only build is installed outside _build/ (what ZagStore-Package.zsh packages)" \
	bash -c "grep -q 'DSTROOT=\"\\\$OUT/dstroot\"' '$ROOT/scripts/build-zag-first-launch-test.sh' && grep -q 'REFUSING: the build changed' '$ROOT/scripts/build-zag-first-launch-test.sh'"
check "the release script refuses test builds (override cleared)" \
	grep -q 'env -u ZAG_ALLOW_FIRST_LAUNCH_TEST_BUILD bash .*zag-check-bundle-contents.sh' "$ROOT/scripts/publish-zag-release.zsh"
check "reporting also needs the user's consent (default off)" \
	grep -q 'UserDefaults.standard.bool(forKey: consentKey)' "$REPORTER"
check "hooked after the interface is interactive" hook_after_interactive
check "the launch gate does not wait for it" bash -c "! grep -q 'await ZagFirstLaunchReporter' '$APP'"
check "the hook starts a detached background task" grep -q 'Task.detached(priority: .background)' "$REPORTER"
check "single call site (no other launch reporting)" \
	test "$(grep -rn 'ZagFirstLaunchReporter\.\(launchBecameInteractive\|shared\)' "$ROOT/Feather" | grep -v "^$REPORTER:" | cut -d: -f1)" = "$APP"
check "no device identifiers or location" \
	bash -c "! grep -nE 'identifierForVendor|advertisingIdentifier|ASIdentifierManager|CLLocation|UIDevice.current.name' '$CORE' '$REPORTER'"
check "ephemeral session without cookies" grep -q 'URLSessionConfiguration.ephemeral' "$REPORTER"
PRIVACY="$ROOT/Feather/Views/Settings/ZagFirstLaunchPrivacyView.swift"
SETTINGS="$ROOT/Feather/Views/Settings/SettingsView.swift"
check "consent toggle defaults to off" \
	grep -q '@AppStorage(ZagFirstLaunchReporter.consentKey) private var _consent = false' "$PRIVACY"
check "disclosure only with the feature on and a document to report" \
	grep -q 'featureEnabled && !UserDefaults.standard.bool(forKey: disclosureShownKey) && bundledAttribution() != nil' "$REPORTER"
check "dismissing the disclosure counts as declining" grep -q 'ZagFirstLaunchReporter.setConsent(false)' "$PRIVACY"
check "both disclosure choices have equal weight" \
	bash -c "! grep -q 'borderedProminent' '$PRIVACY' && grep -q 'buttonStyle(.bordered)' '$PRIVACY'"
check "Settings row only with the feature on" \
	bash -c "grep -B1 'ZagFirstLaunchPrivacyView()' '$SETTINGS' | grep -q 'if ZagFirstLaunchReporter.featureEnabled'"
check "disclosure presenter attached to the app root" grep -q 'ZagFirstLaunchDisclosurePresenter()' "$APP"
check "no background tasks or wake-ups" \
	bash -c "! grep -nE 'BGTaskScheduler|BGAppRefresh|setMinimumBackgroundFetchInterval|beginBackgroundTask' '$CORE' '$REPORTER'"

export ZAG_FIRST_LAUNCH_BODY_OUT="$WORK/body.json"
if swiftc -warnings-as-errors -parse-as-library "$CORE" "$ROOT/scripts/ZagFirstLaunchReportTests.swift" \
	-o "$WORK/report-tests" 2>"$WORK/swiftc.log"; then
	if "$WORK/report-tests"; then echo "PASS  first-launch report unit tests"; else FAILURES=$((FAILURES + 1)); fi
else
	cat "$WORK/swiftc.log"
	echo "FAIL  first-launch report tests did not compile"
	FAILURES=$((FAILURES + 1))
fi

if [[ -n "${ZAG_WEBSITE_REPO:-}" && -f "$WORK/body.json" ]]; then
	interop() {
		python3 -B - "$ZAG_WEBSITE_REPO/server/signing-engine/services" "$WORK/body.json" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import zag_first_launch_endpoint as endpoint
token_hash, metadata = endpoint.parse_request(open(sys.argv[2], "rb").read(), "preview")
assert token_hash is not None and len(token_hash) == 64, token_hash
assert metadata["launched_at"] == "2026-11-12 08:00:00", metadata
PY
	}
	check "server endpoint accepts the app's request body" interop
fi

[[ $FAILURES -eq 0 ]] && echo "All first-launch reporter checks passed" || { echo "$FAILURES failed"; exit 1; }
