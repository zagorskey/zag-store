#!/bin/bash
# Regression checks for the first-launch reporter (preview copies only).
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
# Release: on, preview copies only, no prompt (owner's decision 2026-11-12). The test-only
# build differs only by its marker.
flag_branches() {
	[[ "$(grep -c 'static let featureEnabled' "$REPORTER")" == 1 ]] &&
	grep -q '^	static let featureEnabled = true$' "$REPORTER" &&
	awk '/^#if ZAG_FIRST_LAUNCH_TEST_BUILD$/ {s=1; next} /^#else$/ && s==1 {s=2; next} /^#endif$/ {s=0}
		s==1 && /testBuildMarker: String\? = "ZAG-FIRST-LAUNCH-TEST-BUILD-NOT-FOR-RELEASE"$/ {on=1}
		s==2 && /testBuildMarker: String\? = nil$/ {off=1} s && /featureEnabled/ {bad=1}
		END {exit !(on && off && !bad)}' "$REPORTER"
}
check "feature on; the test-only build differs only by its marker" flag_branches
check "no project setting enables the test-only build" \
	bash -c "! grep -rq 'ZAG_FIRST_LAUNCH_TEST_BUILD' '$ROOT/Feather.xcodeproj' '$ROOT'/*.xcconfig '$ROOT/Feather' --exclude=ZagFirstLaunchReporter.swift"
check "the test-only build is made only by its script, unsigned, no IPA" \
	bash -c "grep -q \"SWIFT_ACTIVE_COMPILATION_CONDITIONS='\\\$(inherited) ZAG_FIRST_LAUNCH_TEST_BUILD'\" '$ROOT/scripts/build-zag-first-launch-test.sh' && grep -q 'CODE_SIGNING_ALLOWED=NO' '$ROOT/scripts/build-zag-first-launch-test.sh' && ! grep -qiE 'zip|\\.ipa|codesign |exportArchive' '$ROOT/scripts/build-zag-first-launch-test.sh'"
check "the test-only build is installed outside _build/ (what ZagStore-Package.zsh packages)" \
	bash -c "grep -q 'DSTROOT=\"\\\$OUT/dstroot\"' '$ROOT/scripts/build-zag-first-launch-test.sh' && grep -q 'REFUSING: the build changed' '$ROOT/scripts/build-zag-first-launch-test.sh'"
check "the release script refuses test builds (override cleared)" \
	grep -q 'env -u ZAG_ALLOW_FIRST_LAUNCH_TEST_BUILD bash .*zag-check-bundle-contents.sh' "$ROOT/scripts/publish-zag-release.zsh"
check "the user's opt-out stops reporting" \
	grep -q 'featureEnabled && !UserDefaults.standard.bool(forKey: optOutKey)' "$REPORTER"
check "preview endpoint only (production reporting disabled)" \
	bash -c "grep -q '\"preview\": URL(string: \"https://preview.zagstore.app/api/zag/v1/first-launch\")' '$CORE' && ! grep -q 'https://zagstore.app' '$CORE' '$REPORTER'"
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
check "sharing toggle defaults to on (no prompt)" \
	grep -q '@AppStorage(ZagFirstLaunchReporter.optOutKey) private var _optedOut = false' "$PRIVACY"
check "no first-launch prompt or sheet" \
	bash -c "! grep -rqE 'ZagFirstLaunchDisclosurePresenter|shouldPresentDisclosure|consentKey' '$ROOT/Feather' && ! grep -q '\\.sheet' '$PRIVACY'"
check "Settings row only in copies with a report" \
	bash -c "grep -B1 'ZagFirstLaunchPrivacyView()' '$SETTINGS' | grep -q 'if ZagFirstLaunchReporter.hasReport'"
check "one report run at a time (duplicate activations)" grep -q 'guard !running, Self.isActive else { return }' "$REPORTER"
check "attempt counted before the request (crash mid-request)" \
	bash -c "awk '/inFlight.attempts \\+= 1/ {a=NR} /await send\\(url:/ {b=NR} END {exit !(a && b && a < b)}' '$REPORTER'"
check "no logging of the document or token" \
	bash -c "! grep -nE 'print\\(|NSLog|os_log|Logger\\(|ZagLog' '$CORE' '$REPORTER'"
check "jailbreak sharing off by default, and only while reporting is on" \
	bash -c "grep -q '@AppStorage(ZagFirstLaunchReporter.jailbreakOptInKey) private var _sharesJailbreak = false' '$PRIVACY' && grep -q 'isActive && UserDefaults.standard.bool(forKey: jailbreakOptInKey)' '$REPORTER'"
check "jailbreak detector: no installed-app queries or library probing" \
	bash -c "! grep -nE 'canOpenURL|LSApplicationQueriesSchemes|_dyld_|dlopen' '$CORE' '$REPORTER'"
check "jailbreak classified only for a report that carries it" \
	grep -q 'let jailbreak = carriesJailbreak ? Self.detectJailbreak() : nil' "$REPORTER"
check "no background tasks or wake-ups" \
	bash -c "! grep -nE 'BGTaskScheduler|BGAppRefresh|setMinimumBackgroundFetchInterval|beginBackgroundTask' '$CORE' '$REPORTER'"

export ZAG_FIRST_LAUNCH_BODY_OUT="$WORK/body.json"
export ZAG_FIRST_LAUNCH_V2_BODIES_OUT="$WORK"
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
	interop_v2() {
		python3 -B - "$ZAG_WEBSITE_REPO/server/signing-engine/services" "$WORK" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import zag_first_launch_endpoint as endpoint
def parse(name):
    token_hash, payload = endpoint.parse_request(open(sys.argv[2] + "/" + name, "rb").read(), "preview")
    assert token_hash is not None and len(token_hash) == 64, token_hash
    assert payload["version"] == 2, payload
    return payload
launch = parse("launch.json")
assert launch["kind"] == "launch" and launch["os_build"] == "23B85" and launch["jailbreak"] is None, launch
assert len(launch["report_id"]) == 22, launch
with_jb = parse("launch-jailbreak.json")
assert with_jb["jailbreak"] == {"consent": "opt_in", "status": "detected", "layout": "rootless", "checks": 1}, with_jb
jb = parse("jailbreak.json")
assert jb["kind"] == "jailbreak" and jb["jailbreak"]["status"] == "unknown" and "metadata" not in jb, jb
PY
	}
	check "server endpoint accepts the app's v2 launch and jailbreak reports" interop_v2
fi

[[ $FAILURES -eq 0 ]] && echo "All first-launch reporter checks passed" || { echo "$FAILURES failed"; exit 1; }
