#!/bin/bash
# Regression checks for background refresh completion and the iOS 26
# continued-processing download identifier.
# Usage: bash scripts/test-zag-background-refresh.sh [path/to/built/Feather.app]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_SWIFT="$ROOT/Feather/FeatherApp.swift"
MANAGER="$ROOT/Feather/Utilities/BackgroundTaskManager.swift"
PLIST="$ROOT/Feather/Resources/Info.plist"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-background-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
FAILURES=0

check() {
	local label="$1"; shift
	if "$@"; then echo "PASS  $label"; else echo "FAIL  $label"; FAILURES=$((FAILURES + 1)); fi
}

handle=$(awk '/private func handle\(_ task: BGAppRefreshTask\)/ {inside=1} inside {print} inside && /^\t}$/ {exit}' "$APP_SWIFT")
expiry=$(awk '/task.expirationHandler = \{/ {inside=1} inside {print} inside && /^\t\t}$/ {exit}' <<< "$handle")

check "refresh completion goes through ZagOnceCompletion" grep -q 'ZagOnceCompletion' <<< "$handle"
check "expiration handler reports completion" grep -q 'completion.complete(success: false)' <<< "$expiry"
check "no early return that skips completion" bash -c "! grep -q 'guard !Task.isCancelled else { return }' <<< \"\$1\"" _ "$handle"
check "Info.plist permits the userTask wildcard" grep -qF '.userTask.*</string>' "$PLIST"
check "refresh identifier still permitted" grep -qF 'com.cwd43.gu29.background-update-check' "$PLIST"
check "download tasks use the permitted identifier" grep -q 'ZagBackgroundTaskIdentifiers.continuedDownloadPrefix' "$MANAGER"
check "registration result is checked" grep -q 'let registered = BGTaskScheduler.shared.register' "$MANAGER"
check "no force-unwrapped bundle identifier" bash -c "! grep -q 'bundleIdentifier!' '$MANAGER'"

run_swift_tests() {
	local name="$1" source="$2" tests="$3"
	if swiftc -warnings-as-errors -parse-as-library "$source" "$tests" -o "$WORK/$name" 2>"$WORK/$name.log"; then
		if "$WORK/$name"; then echo "PASS  $name"; else FAILURES=$((FAILURES + 1)); fi
	else
		cat "$WORK/$name.log"; echo "FAIL  $name did not compile"; FAILURES=$((FAILURES + 1))
	fi
}
run_swift_tests "once-completion unit tests" \
	"$ROOT/Feather/Utilities/ZagOnceCompletion.swift" "$ROOT/scripts/ZagOnceCompletionTests.swift"
run_swift_tests "identifier unit tests" \
	"$ROOT/Feather/Utilities/ZagBackgroundTaskIdentifiers.swift" "$ROOT/scripts/ZagBackgroundTaskIdentifiersTests.swift"

# Optional: confirm the built Info.plist expanded the wildcard.
if [[ $# -ge 1 ]]; then
	ids=$(plutil -extract BGTaskSchedulerPermittedIdentifiers json -o - "$1/Info.plist")
	bundle=$(plutil -extract CFBundleIdentifier raw "$1/Info.plist")
	check "built plist expands the wildcard for $bundle" grep -qF "\"$bundle.userTask.*\"" <<< "$ids"
	check "built plist has no unexpanded build setting" bash -c "! grep -qF '\$(' <<< \"\$1\"" _ "$ids"
fi

if (( FAILURES > 0 )); then
	echo "$FAILURES check(s) failed"
	exit 1
fi
echo "Background refresh checks passed"
