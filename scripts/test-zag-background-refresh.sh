#!/bin/bash
# Regression checks for background refresh completion and the iOS 26
# continued-processing download task.
# Usage: bash scripts/test-zag-background-refresh.sh [path/to/built/Feather.app]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_SWIFT="$ROOT/Feather/FeatherApp.swift"
MANAGER="$ROOT/Feather/Utilities/BackgroundTaskManager.swift"
DOWNLOADS="$ROOT/Feather/Backend/Observable/DownloadManager.swift"
PLIST="$ROOT/Feather/Resources/Info.plist"
UTIL="$ROOT/Feather/Utilities"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-background-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
FAILURES=0

check() {
	local label="$1"; shift
	if "$@"; then echo "PASS  $label"; else echo "FAIL  $label"; FAILURES=$((FAILURES + 1)); fi
}
absent() { ! grep -q "$1" <<< "$2"; }

# Print a Swift function body (from a signature prefix to the next "func ").
function_body() {
	awk -v sig="func $2" '
		index($0, sig) { inside = 1; print; next }
		inside && /^[[:space:]]*(private |fileprivate |static |@discardableResult )*func / { exit }
		inside { print }
	' "$1"
}

# Background update refresh (BGAppRefreshTask).
handle=$(awk '/private func handle\(_ task: BGAppRefreshTask\)/ {inside=1} inside {print} inside && /^\t}$/ {exit}' "$APP_SWIFT")
expiry=$(awk '/task.expirationHandler = \{/ {inside=1} inside {print} inside && /^\t\t}$/ {exit}' <<< "$handle")
check "refresh completion goes through ZagOnceCompletion" grep -q 'ZagOnceCompletion' <<< "$handle"
check "expiration handler reports completion" grep -q 'completion.complete(success: false)' <<< "$expiry"
check "no early return that skips completion" absent 'guard !Task.isCancelled else { return }' "$handle"

# Identifier permissions.
check "Info.plist permits the userTask wildcard" grep -qF '<string>$(PRODUCT_BUNDLE_IDENTIFIER).userTask.*</string>' "$PLIST"
check "refresh identifier still permitted" grep -qF 'com.cwd43.gu29.background-update-check' "$PLIST"
check "download tasks use the permitted identifier" grep -q 'ZagBackgroundTaskIdentifiers.continuedDownloadPrefix()' "$MANAGER"
check "registration result is checked" grep -q 'let registered = BGTaskScheduler.shared.register' "$MANAGER"
check "no force-unwrapped bundle identifier" absent 'bundleIdentifier!' "$(cat "$MANAGER")"

# Continued-download task lifecycle.
manager=$(cat "$MANAGER")
check "manager completes tasks only through the ledger" \
	bash -c "[[ \$(grep -c 'setTaskCompleted' <<< \"\$1\") -eq 2 ]] && grep -q 'complete: { success in' <<< \"\$1\"" _ "$manager"
check "registration is tracked by the ledger" grep -q 'ledger.isRegistered(taskIdentifier)' <<< "$manager"
check "expiry goes through the ledger before cancelling" grep -q 'let expiredTransfer = self.ledger.expire(taskIdentifier, token: token) else { return }' <<< "$manager"
check "expiry cancels only the expired transfer" grep -q 'ZagContinuedTaskLedger.download(using: expiredTransfer, in: manager.downloads, transfer: { $0.task })' <<< "$manager"
check "expiry never looks a download up by identifier" absent 'getDownload(by:' "$manager"
check "ledger calls are scoped to the transfer" \
	bash -c "grep -q 'willSubmit(taskIdentifier, transfer: transfer)' <<< \"\$1\" && grep -q 'ledger.finish(taskIdentifier, transfer: transfer' <<< \"\$1\" && grep -q 'runningTask(taskIdentifier, transfer: transfer)' <<< \"\$1\"" _ "$manager"
check "download is cancelled on the main queue after expiry" grep -q 'DispatchQueue.main.async' <<< "$manager"
check "queued request is cancelled when the download ends first" grep -q 'cancel(taskRequestWithIdentifier: taskIdentifier)' <<< "$manager"
check "progress no longer completes the task early" absent 'stopTask' "$(function_body "$MANAGER" "updateProgress(")"
check "no unsynchronised task dictionary" absent 'activeTasks' "$manager"
check "cancelled downloads end their task" grep -q 'stopTask(for: download, success: false)' <<< "$(function_body "$DOWNLOADS" "cancelDownload(")"
check "import result ends the task" grep -q 'stopTask(for: dl, success: err == nil)' <<< "$(function_body "$DOWNLOADS" "handlePachageFile(")"
check "file handling failure ends the task" grep -q 'stopTask(for: download, success: false)' <<< "$(function_body "$DOWNLOADS" "urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo")"
check "transfer failure ends the task" grep -q 'stopTask(for: download, success: false)' <<< "$(function_body "$DOWNLOADS" "urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError")"

run_swift_tests() {
	local name="$1"; shift
	if swiftc -warnings-as-errors -parse-as-library "$@" -o "$WORK/test" 2>"$WORK/test.log"; then
		if "$WORK/test"; then echo "PASS  $name"; else echo "FAIL  $name"; FAILURES=$((FAILURES + 1)); fi
	else
		cat "$WORK/test.log"; echo "FAIL  $name did not compile"; FAILURES=$((FAILURES + 1))
	fi
}
run_swift_tests "once-completion unit tests" \
	"$UTIL/ZagOnceCompletion.swift" "$ROOT/scripts/ZagOnceCompletionTests.swift"
run_swift_tests "identifier unit tests" \
	"$UTIL/ZagBackgroundTaskIdentifiers.swift" "$ROOT/scripts/ZagBackgroundTaskIdentifiersTests.swift"
run_swift_tests "continued-task ledger unit tests" \
	"$UTIL/ZagOnceCompletion.swift" "$UTIL/ZagContinuedTaskLedger.swift" "$ROOT/scripts/ZagContinuedTaskLedgerTests.swift"

# Optional: check the built Info.plist.
if [[ $# -ge 1 ]]; then
	ids=$(plutil -extract BGTaskSchedulerPermittedIdentifiers json -o - "$1/Info.plist")
	bundle=$(plutil -extract CFBundleIdentifier raw "$1/Info.plist")
	check "built plist permits $bundle.userTask.*" grep -qF "\"$bundle.userTask.*\"" <<< "$ids"
	check "built plist has no unexpanded build setting" absent '\$(' "$ids"
	sample="$bundle.userTask.$(printf '%s' sample-download-id | md5 -q)"
	matches_permitted() {
		local pattern
		while IFS= read -r pattern; do
			# shellcheck disable=SC2053
			[[ "$sample" == $pattern ]] && return 0
		done < <(plutil -extract BGTaskSchedulerPermittedIdentifiers xml1 -o - "$1/Info.plist" | sed -n 's/.*<string>\(.*\)<\/string>.*/\1/p')
		return 1
	}
	check "generated identifier $sample matches a permitted pattern" matches_permitted "$1"
fi


# Refresh performance: each finished repository publishes SourcesViewModel.
# Only views that render repository state may observe it, or every refresh
# re-renders the tab root and every Apps row once per repository.
VIEWS="$ROOT/Feather/Views"
check "root tab view does not observe SourcesViewModel" \
	absent 'Object.*SourcesViewModel' "$(cat "$VIEWS/TabView/VariedTabbarView.swift")"
check "root tab view does not observe UpdateManager" \
	absent '@StateObject private var updateManager = UpdateManager.shared' "$(sed -n '/^struct VariedTabbarView/,/^}/p' "$VIEWS/TabView/VariedTabbarView.swift")"
check "iOS 18 tab container does not observe SourcesViewModel" \
	absent 'Object.*SourcesViewModel' "$(cat "$VIEWS/TabView/Bars/ExtendedTabbarView.swift")"
check "Apps page and Updates popup do not observe SourcesViewModel" \
	absent 'Object.*SourcesViewModel' "$(cat "$VIEWS/Library/LibraryView.swift")"
cell_struct=$(sed -n '/^struct LibraryCellView/,/^}/p' "$VIEWS/Library/LibraryCellView.swift")
check "Apps rows do not observe SourcesViewModel" absent 'SourcesViewModel' "$cell_struct"
check "Apps row badge observes repository state itself" \
	grep -q 'private struct ZagLibraryRepositoryBadge' "$VIEWS/Library/LibraryCellView.swift"
TABS="$VIEWS/TabView/TabEnum.swift"
check "Games indexes from the published repository snapshot" \
	grep -q '\.onReceive(sourcesModel\.\$sources) { loaded in' "$TABS"
check "Games rebuilds when a refresh ends (finished, failed or cancelled)" \
	grep -q '\.onReceive(sourcesModel\.\$isRefreshing\.dropFirst()) { refreshing in' "$TABS"
check "Games shows only the newest build's result" grep -q 'indexState.accepts(generation: generation)' "$TABS"
check "Games no longer depends on objectWillChange ordering" absent 'sourcesModel.objectWillChange' "$(cat "$TABS")"
fetch_body=$(function_body "$VIEWS/Sources/SourcesViewModel.swift" fetchSources)
refresh_cleared_in_defer() {
	[[ $(grep -c 'self.isRefreshing = false' <<< "$fetch_body") == 1 ]] &&
	awk '/defer {/{d=1} d && /self.isRefreshing = false/{found=1} d && /^\t\t}/{d=0} END{exit !found}' <<< "$fetch_body"
}
check "isRefreshing is cleared only in fetchSources' defer, after every snapshot" refresh_cleared_in_defer
LIB="$VIEWS/Library/LibraryView.swift"
check "Updates popup persists once per completed reconciliation" \
	grep -q '\.onReceive(updateManager\.\$reconciliationGeneration\.dropFirst()) {' "$LIB"
check "Updates popup no longer persists on repository publications" absent 'onReceive(sourcesViewModel\.\$' "$(cat "$LIB")"
check "Updates popup persistence is not deferred" absent 'DispatchQueue.main.async { _cacheAvailableRows() }' "$(cat "$LIB")"
generation_is_last() {
	local body; body=$(sed -n '/func refresh(\n*/,/^\t}$/p' "$1")
	local done_line gen_line
	done_line=$(grep -n 'forKey: Self.persistedUpdateCountKey' "$1" | tail -1 | cut -d: -f1)
	gen_line=$(grep -n 'reconciliationGeneration &+= 1' "$1" | cut -d: -f1)
	local completed_line; completed_line=$(grep -n 'hasCompletedReconciliation = true' "$1" | cut -d: -f1)
	[[ -n "$gen_line" && "$gen_line" -gt "$done_line" && "$gen_line" -gt "$completed_line" ]]
}
check "reconciliation signal publishes after updates and counts are final" \
	generation_is_last "$VIEWS/Sources/SourcesViewModel.swift"
SVM="$VIEWS/Sources/SourcesViewModel.swift"
check "visibleUpdates reuses decoded Updated Recently rows" \
	grep -q 'let recent = _recentUpdateRows()' "$SVM"
check "decoded rows are reused only while the stored bytes are unchanged" \
	grep -q 'if let cache = recentRowsCache, cache.data == data {' "$SVM"
check "build lookups are remembered for one reconciliation only" \
	bash -c 'grep -q "buildVersionMemo = \[:\]" "$1" && grep -q "defer { buildVersionMemo = nil }" "$1"' _ "$SVM"

FETCH="$ROOT/NimbleKit/Sources/NimbleJSON/NBFetchService.swift"
diagnostics_off_defaults() {
	local body; body=$(awk '/^public enum NBRepositoryFetchDiagnostics/{f=1} f&&/^}/{print; exit} f' "$FETCH")
	[[ -n "$body" ]] && ! grep -q 'UserDefaults.standard.set' <<< "$body"
}
check "Fetch diagnostics are not stored in UserDefaults (root re-evaluated per repository)" diagnostics_off_defaults
check "Cache validators are written only when they change" \
	grep -q 'guard defaults.string(forKey: key) != value else { return }' "$FETCH"
check "Fetch completion writes validators only through storeValidator" absent 'defaults.set(\s*$' "$(cat "$FETCH")"

FETCH_WORK=$(mktemp -d "${TMPDIR:-/tmp}/zag-fetch-defaults.XXXXXX")
if swiftc -warnings-as-errors -parse-as-library -module-name ZagFetchDefaultsTests \
	"$FETCH" "$ROOT/scripts/ZagFetchDefaultsTests.swift" \
	-o "$FETCH_WORK/tests" 2>"$FETCH_WORK/swiftc.log"; then
	if (cd "$FETCH_WORK" && HOME="$FETCH_WORK" ./tests); then echo "PASS  fetch defaults behaviour tests"; else FAILURES=$((FAILURES + 1)); fi
else
	cat "$FETCH_WORK/swiftc.log"
	echo "FAIL  fetch defaults tests did not compile"
	FAILURES=$((FAILURES + 1))
fi
rm -rf "$FETCH_WORK"

LIFECYCLE_WORK=$(mktemp -d "${TMPDIR:-/tmp}/zag-refresh-lifecycle.XXXXXX")
if swiftc -warnings-as-errors -parse-as-library \
	"$ROOT/Feather/Utilities/ZagRepositoryIndexState.swift" \
	"$ROOT/Feather/Views/Library/ZagUpdateRowSnapshot.swift" \
	"$ROOT/scripts/ZagRefreshLifecycleTests.swift" \
	-o "$LIFECYCLE_WORK/tests" 2>"$LIFECYCLE_WORK/swiftc.log"; then
	if "$LIFECYCLE_WORK/tests"; then echo "PASS  refresh lifecycle behaviour tests"; else FAILURES=$((FAILURES + 1)); fi
else
	cat "$LIFECYCLE_WORK/swiftc.log"
	echo "FAIL  refresh lifecycle tests did not compile"
	FAILURES=$((FAILURES + 1))
fi
rm -rf "$LIFECYCLE_WORK"

if (( FAILURES > 0 )); then
	echo "$FAILURES check(s) failed"
	exit 1
fi
echo "Background refresh checks passed"
