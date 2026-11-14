#!/bin/bash
# Regression checks for the anonymous usage activity reporter.
# Usage: bash scripts/test-zag-activity-report.sh
# With ZAG_WEBSITE_REPO set to the website checkout, the request bodies built
# here are also parsed by the server endpoint's own validator.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/Feather/Utilities/ZagActivityReport.swift"
REPORTER="$ROOT/Feather/Utilities/ZagActivityReporter.swift"
FIRST_LAUNCH="$ROOT/Feather/Utilities/ZagFirstLaunchReporter.swift"
APP="$ROOT/Feather/FeatherApp.swift"
PRIVACY="$ROOT/Feather/Views/Settings/ZagFirstLaunchPrivacyView.swift"
SETTINGS="$ROOT/Feather/Views/Settings/SettingsView.swift"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-activity-tests.XXXXXX")
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
	hook=$(grep -n 'ZagActivityReporter.launchBecameInteractive()' <<< "$finish_body" | head -1 | cut -d: -f1)
	[[ -n "$interactive" && -n "$hook" && "$interactive" -lt "$hook" ]]
}
check "started after the interface is interactive" hook_after_interactive
check "single start call site" \
	test "$(grep -rln 'ZagActivityReporter\.launchBecameInteractive()' "$ROOT/Feather" | grep -v "^$REPORTER$")" = "$APP"
check "the launch gate does not wait for it" bash -c "! grep -q 'await ZagActivityReporter' '$APP'"
check "on by default; the opt-out is checked before every event" \
	bash -c "grep -q '^	nonisolated static let featureEnabled = true$' '$REPORTER' && grep -q 'featureEnabled && !UserDefaults.standard.bool(forKey: optOutKey)' '$REPORTER' && grep -q 'guard canSend, let url = endpoint' '$REPORTER'"
check "opt-out stops the heartbeat, cancels requests and forgets the session" \
	bash -c "awk '/private func shutDown\\(\\)/ {s=1} s && /stopHeartbeat\\(\\)/ {h=1} s && /session.reset\\(\\)/ {r=1} s && /getAllTasks/ {c=1} s && /^	}$/ {exit !(h && r && c)}' '$REPORTER'"
check "own opt-out key, independent of the first-launch report" \
	bash -c "grep -q 'nonisolated static let optOutKey = \"ZagStore.usageAnalyticsOptOut\"' '$REPORTER' && ! grep -q 'usageAnalytics' '$FIRST_LAUNCH'"
check "exactly the two website endpoints, no other URL" \
	bash -c "[ \"\$(grep -c 'https://' '$CORE' '$REPORTER' | awk -F: '{s+=\$2} END {print s}')\" = 2 ]"
check "preview for unattributed copies only in the test-only build" \
	grep -q 'testBuild: ZagFirstLaunchReporter.testBuildMarker != nil' "$REPORTER"
check "no device identifiers, location or app inventory" \
	bash -c "! grep -nE 'identifierForVendor|advertisingIdentifier|ASIdentifierManager|CLLocation|UIDevice.current.name|hw.machine|canOpenURL|LSApplicationWorkspace' '$CORE' '$REPORTER'"
check "nothing stored on disk but the opt-out" \
	bash -c "! grep -nE 'FileManager|write\\(to|UserDefaults.standard.set\\(' '$CORE' '$REPORTER' | grep -v 'set(!enabled, forKey: optOutKey)'"
check "no logging" bash -c "! grep -nE 'print\\(|NSLog|os_log|Logger\\(|ZagLog' '$CORE' '$REPORTER'"
check "no background tasks or wake-ups" \
	bash -c "! grep -nE 'BGTaskScheduler|BGAppRefresh|beginBackgroundTask|backgroundSessionConfiguration|\\.background\\(' '$CORE' '$REPORTER'"
check "ephemeral session without cookies, bounded timeouts" \
	bash -c "grep -q 'URLSessionConfiguration.ephemeral' '$REPORTER' && grep -q 'timeoutIntervalForRequest = 10' '$REPORTER' && grep -q 'timeoutIntervalForResource = 15' '$REPORTER'"
check "bounded requests in flight, no event queue" \
	bash -c "grep -q 'private static let maxInFlight = 2' '$REPORTER' && ! grep -nE '\\[ZagActivityReport.Session.Step\\]|queue\\.append|pending\\.append' '$REPORTER'"
check "Privacy row in every copy" \
	bash -c "grep -B1 'ZagFirstLaunchPrivacyView()' '$SETTINGS' | grep -q NavigationLink && ! grep -B2 'ZagFirstLaunchPrivacyView()' '$SETTINGS' | grep -q 'hasReport'"
check "usage toggle on by default, in Settings › Privacy" \
	bash -c "grep -q '@AppStorage(ZagActivityReporter.optOutKey) private var _activityOptedOut = false' '$PRIVACY' && grep -q 'ZagActivityReporter.setSharing(\$0)' '$PRIVACY'"
check "disclosure states the default, the opt-out and retention" \
	bash -c "grep -q 'On by default' '$PRIVACY' && grep -q 'Turn this off and nothing more is sent' '$PRIVACY' && grep -q '30 days and hourly totals after 90 days' '$PRIVACY'"

export ZAG_ACTIVITY_BODIES_OUT="$WORK"
if swiftc -warnings-as-errors -parse-as-library "$CORE" "$ROOT/scripts/ZagActivityReportTests.swift" \
	-o "$WORK/activity-tests" 2>"$WORK/swiftc.log"; then
	if "$WORK/activity-tests"; then echo "PASS  activity report unit tests"; else FAILURES=$((FAILURES + 1)); fi
else
	cat "$WORK/swiftc.log"
	echo "FAIL  activity report tests did not compile"
	FAILURES=$((FAILURES + 1))
fi

if [[ -n "${ZAG_WEBSITE_REPO:-}" && -f "$WORK/start.json" ]]; then
	interop() {
		python3 -B - "$ZAG_WEBSITE_REPO/server/signing-engine/services" "$WORK" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import zag_app_activity as activity
for name, event, seq in (("start", "start", 0), ("heartbeat", "heartbeat", 1), ("end", "end", 2)):
    event_ = activity.parse_event(open(sys.argv[2] + "/" + name + ".json", "rb").read())
    assert event_["event"] == event and event_["seq"] == seq and event_["app_build"] == "3", event_
PY
	}
	check "server endpoint accepts the app's activity events" interop
fi

[[ $FAILURES -eq 0 ]] && echo "All activity reporter checks passed" || { echo "$FAILURES failed"; exit 1; }
