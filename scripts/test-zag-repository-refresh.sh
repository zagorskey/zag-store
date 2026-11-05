#!/usr/bin/env bash
# Repository refresh and update-input regression tests (host, no network).
# Runs with a temporary HOME so the fetch service's caches and the test
# process's defaults never touch the real user directories.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/zag-refresh-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home/Library/Caches" "$WORK/home/Library/Preferences"

xcrun swiftc -parse-as-library -O \
	"$ROOT/Feather/Utilities/ZagInstalledInventory.swift" \
	"$ROOT/Feather/Utilities/ZagRepositoryRefreshRecord.swift" \
	"$ROOT/NimbleKit/Sources/NimbleJSON/NBFetchService.swift" \
	"$ROOT/scripts/ZagRepositoryRefreshTests.swift" \
	-o "$WORK/tests"

HOME="$WORK/home" CFFIXED_USER_HOME="$WORK/home" "$WORK/tests" | tee "$WORK/out.log"
fail=0
SVM="$ROOT/Feather/Views/Sources/SourcesViewModel.swift"
check() { if "$@" >/dev/null 2>&1; then echo "PASS  $name"; else echo "FAIL  $name"; fail=1; fi; }

name="pipeline: update matching uses the resolved installed apps, not only a live read"
check bash -c "grep -q 'let inventory = currentInventory()' '$SVM' && grep -q 'if inventory.isDeviceInventory {' '$SVM' && ! grep -q 'let deviceInventory = pairingCore.installedApps' '$SVM'"
name="pipeline: cold start and manual refresh reconcile through the same gate"
check bash -c "grep -q 'let hasAuthoritativeInventory = UpdateManager.shared.currentInventory().isDeviceInventory' '$SVM'"
name="pipeline: every successful device read is saved for later"
check bash -c "grep -q 'ZagInventorySnapshotStore.shared.save(' '$ROOT/Feather/Utilities/ZagInventorySnapshotRecorder.swift' && grep -q 'ZagInventorySnapshotRecorder.shared.start()' '$ROOT/Feather/FeatherApp.swift'"
name="pipeline: the RPPairing core is untouched"
check bash -c "cd '$ROOT' && git diff --quiet HEAD -- Feather/RPPairing"
name="pipeline: reconciliation runs after the repository snapshot is published"
check bash -c "awk '/self.sources = completedSources/{p=NR} /await _refreshUpdatesUsingInstalledInventory\\(/{if(p&&NR>p)ok=1} END{exit !ok}' '$SVM'"
name="pipeline: an incomplete repository snapshot never replaces the update set"
check bash -c "grep -q 'guard missingSourceURLs.isEmpty else' '$SVM' && grep -q 'guard repositories.count == sources.count else' '$ROOT/Feather/FeatherApp.swift'"
name="pipeline: foreground and background refreshes publish in start order"
check bash -c "grep -q 'snapshotStartedAt: snapshotStartedAt' '$SVM' && grep -q 'snapshotStartedAt: snapshotStartedAt' '$ROOT/Feather/FeatherApp.swift' && grep -q 'refreshOrdering.admit(snapshotStartedAt:' '$SVM'"
name="pipeline: badge, Apps page and Updates popup share one update set"
check bash -c "grep -q 'setBadgeCount(updateCount)' '$SVM' && grep -q 'if hasCompletedReconciliation { return visibleUpdates.count }' '$SVM'"
name="pipeline: repository refresh never runs the Mobile Data Shortcut or restricts by network"
check bash -c "! grep -nE 'ZagMobileDataToggle|shortcuts://|isExpensive|isConstrained|allowsCellularAccess' '$SVM' '$ROOT/NimbleKit/Sources/NimbleJSON/NBFetchService.swift'"
name="pipeline: diagnostics report repository outcomes and the installed-app source"
check bash -c "grep -q 'diagnosticLines.append(contentsOf: summary.lines())' '$SVM' && grep -q 'Installed apps used:' '$SVM' && grep -q 'Update count: ' '$SVM'"

if grep -q '^FAIL' "$WORK/out.log" || [ $fail -ne 0 ]; then
	echo "Repository refresh tests FAILED"
	exit 1
fi
echo "Repository refresh tests passed"
