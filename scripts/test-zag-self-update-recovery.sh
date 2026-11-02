#!/bin/bash
# Regression checks for self-update marker provisioning and safe retry.
# Usage: bash scripts/test-zag-self-update-recovery.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COORD="$ROOT/Feather/Utilities/ZagSelfUpdateCoordinator.swift"
PROBE="$ROOT/Feather/Utilities/ZagSelfUpdateKeychainProbe.swift"
VIEW="$ROOT/Feather/Views/Settings/ZagSelfUpdateStatusView.swift"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-selfupdate-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
FAILURES=0

check() {
	local label="$1"; shift
	if "$@"; then echo "PASS  $label"; else echo "FAIL  $label"; FAILURES=$((FAILURES + 1)); fi
}

# Print the body of a Swift function (from its signature to the next "func ").
function_body() {
	awk -v name="$2" '
		$0 ~ "func " name "\\(" { inside = 1; print; next }
		inside && /^[[:space:]]*(private |fileprivate |static )*func / { exit }
		inside { print }
	' "$1"
}

stage=$(function_body "$COORD" stageSignedSelfUpdate)
perform=$(function_body "$COORD" performPreparedHandoff)
clear=$(function_body "$COORD" clearFailedHandoff)

marker_before_group() {
	local create group
	create=$(grep -n 'ZagSelfUpdateKeychainProbe.createIfMissing()' <<< "$stage" | head -1 | cut -d: -f1)
	group=$(grep -n 'markerAccessGroup()' <<< "$stage" | head -1 | cut -d: -f1)
	[[ -n "$create" && -n "$group" && "$create" -lt "$group" ]]
}
check "staging provisions the marker before reading its group" marker_before_group
check "candidate must still contain the marker's keychain group" \
	grep -q 'candidate.contains(markerGroup)' <<< "$stage"
check "keychain mismatch has its own error" grep -q 'keychainContinuityMismatch' <<< "$stage"
check "probe error shows the real OSStatus" bash -c "! grep -qF '\\\\(status)' '$PROBE'"
check "failed attempts consult the retry policy" grep -q 'ZagSelfUpdateRetryPolicy.mayReleasePendingRecord' <<< "$perform"
check "retry path never touches the rollback store" \
	bash -c "! grep -qE 'RollbackStore|recordAccepted' <<< \"\$1\$2\"" _ "$perform" "$clear"
check "clearing only removes the pending record" \
	bash -c "grep -q 'removeObject(forKey: pendingKey)' <<< \"\$1\" && ! grep -q 'completedKey' <<< \"\$1\"" _ "$clear"
check "users can clear an unconfirmed attempt outside diagnostics" \
	grep -q 'Clear and Try Again' "$VIEW"
check "update failures are shown to every user" grep -q 'userVisibleUpdateIssue' "$VIEW"

submit=$(function_body "$COORD" submitStagedUpdateToGate4)
snapshot_before_resume() {
	local snap resume
	snap=$(grep -n 'onFinished(ZagRPPairingCore.shared.gate4AttemptEvents)' <<< "$submit" | head -1 | cut -d: -f1)
	resume=$(grep -n 'continuation.resume(with: result)' <<< "$submit" | head -1 | cut -d: -f1)
	[[ -n "$snap" && -n "$resume" && "$snap" -lt "$resume" ]]
}
check "callbacks are snapshotted when the attempt ends" snapshot_before_resume
check "policy classifies the snapshot, not live state" \
	grep -q 'ZagSelfUpdateRetryPolicy.progress(afterEvents: finishedEvents)' <<< "$perform"
check "no classification from the shared live callback list" \
	bash -c "! grep -qE 'gate4AttemptEvents|gate4AttemptCallbackCodes' <<< \"\$1\"" _ "$perform"

# The policy's assumptions about the native installer must still hold.
RUST="$ROOT/RPPairingCore/rust-core/src/lib.rs"
if [[ -f "$RUST" ]]; then
	install_fn=$(awk '/^async fn run_gate4_install\(/ {inside=1} inside {print} inside && /^}$/ {exit}' "$RUST")
	streamed_id=$(sed -n 's/.*streamedSelfUpdateAnnouncement = "Upgrading \(.*\)"/\1/p' "$ROOT/Feather/Utilities/ZagSelfUpdateRetryPolicy.swift")
	before_205=$(awk '/^[[:space:]]*205,$/ {exit} {print}' <<< "$install_fn")
	check "Rust streamed path uses the policy's bundle ID ($streamed_id)" \
		grep -qF "if bundle_id == \"$streamed_id\" && is_upgrade {" <<< "$install_fn"
	check "Rust 205 message format matches the policy" \
		grep -qF 'if is_upgrade { "Upgrading" } else { "Installing" }' <<< "$install_fn"
	staged_before_upgrade() {
		local staged upgrade
		staged=$(grep -n 'emit(callback, 209' <<< "$install_fn" | head -1 | cut -d: -f1)
		upgrade=$(grep -n 'upgrade_with_callback' <<< "$install_fn" | head -1 | cut -d: -f1)
		[[ -n "$staged" && -n "$upgrade" && "$staged" -lt "$upgrade" ]]
	}
	check "Rust emits 209 before the streamed Upgrade request" staged_before_upgrade
	check "Rust found the 205 announcement" test -n "$before_205" -a "$before_205" != "$install_fn"
	check "Rust sends no install or upgrade before 205" \
		bash -c "! grep -qE 'upgrade_|install_package|AfcClient' <<< \"\$1\"" _ "$before_205"
else
	echo "FAIL  Rust installer source missing (initialise the RPPairingCore submodule)"
	FAILURES=$((FAILURES + 1))
fi

# Compile and run the pure policy tests.
if swiftc -warnings-as-errors -parse-as-library \
	"$ROOT/Feather/Utilities/ZagSelfUpdateRetryPolicy.swift" \
	"$ROOT/scripts/ZagSelfUpdateRetryPolicyTests.swift" \
	-o "$WORK/policy-tests" 2>"$WORK/swiftc.log"; then
	if "$WORK/policy-tests"; then echo "PASS  retry policy unit tests"; else FAILURES=$((FAILURES + 1)); fi
else
	cat "$WORK/swiftc.log"
	echo "FAIL  retry policy tests did not compile"
	FAILURES=$((FAILURES + 1))
fi

if (( FAILURES > 0 )); then
	echo "$FAILURES check(s) failed"
	exit 1
fi
echo "Self-update recovery checks passed"
