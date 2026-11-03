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

# Gate4 callbacks reach Swift in order, on the main actor, one attempt at a time.
CORE="$ROOT/Feather/RPPairing/ZagRPPairingCore.swift"
bridge=$(awk '/^private func zagGate4Callback\(/ {inside=1} inside {print} inside && /^}$/ {exit}' "$CORE")
install_swift=$(function_body "$CORE" installGate4IPA)
receive=$(function_body "$CORE" receiveGate4)
copies_before_hop() {
	local copy hop
	copy=$(grep -n 'String(cString:' <<< "$bridge" | head -1 | cut -d: -f1)
	hop=$(grep -n 'DispatchQueue.main.async' <<< "$bridge" | head -1 | cut -d: -f1)
	[[ -n "$copy" && -n "$hop" && "$copy" -lt "$hop" ]]
}
check "Gate4 C message is copied before leaving the native thread" copies_before_hop
check "Gate4 callbacks are forwarded through the serial main queue only" \
	bash -c "[[ \$(grep -c 'DispatchQueue' <<< \"\$1\") -eq 1 ]] && grep -q 'ZagRPPairingCore.shared.receiveGate4(code: code, message: text)' <<< \"\$1\"" _ "$bridge"
check "Gate4 state is main-actor isolated" \
	bash -c "grep -B1 '^final class ZagRPPairingCore' \"\$1\" | grep -q '^@MainActor'" _ "$CORE"
event_before_completion() {
	local append first_completion
	append=$(grep -n 'gate4AttemptEvents.append' <<< "$receive" | head -1 | cut -d: -f1)
	first_completion=$(grep -n 'gate4Completion?(' <<< "$receive" | head -1 | cut -d: -f1)
	[[ -n "$append" && -n "$first_completion" && "$append" -lt "$first_completion" ]]
}
check "terminal callback is recorded before the completion snapshots it" event_before_completion
guard_before_store() {
	local guard_line store
	guard_line=$(grep -n 'guard !isGate4Running' <<< "$install_swift" | head -1 | cut -d: -f1)
	store=$(grep -n 'gate4Completion = completion' <<< "$install_swift" | head -1 | cut -d: -f1)
	[[ -n "$guard_line" && -n "$store" && "$guard_line" -lt "$store" ]]
}
check "a running attempt is refused before its completion is replaced" guard_before_store
check "every early failure clears the stored completion" \
	bash -c "[[ \$(grep -cE '\bthrow ' <<< \"\$1\") -eq \$(( \$(grep -c 'gate4Completion = nil' <<< \"\$1\") + 1 )) ]]" _ "$install_swift"

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
	entry=$(awk '/^pub unsafe extern "C" fn zag_gate4_install\(/ {inside=1} inside {print} inside && /^}$/ {exit}' "$RUST")
	session=$(awk '/^async fn with_zag_device_session/ {inside=1} inside {print} inside && /^}$/ {exit}' "$RUST")
	check "Rust Gate4 runs on one worker thread driven by block_on" \
		bash -c "[[ \$(grep -c 'thread::spawn' <<< \"\$1\") -eq 1 ]] && grep -q 'runtime.block_on' <<< \"\$1\"" _ "$entry"
	check "Rust Gate4 never spawns tasks that could emit out of order" \
		bash -c "! grep -qE 'spawn' <<< \"\$1\$2\"" _ "$install_fn" "$session"
	check "Rust emits -4 only after the installer returns" \
		bash -c "! grep -q 'emit(callback, -4' <<< \"\$1\" && grep -q 'run_gate4_install(device_ip, pairing_path, ipa_path, callback).await' <<< \"\$2\"" _ "$install_fn" "$entry"
	last_emit_is_207() {
		local last
		last=$(grep -n 'emit(callback, ' <<< "$install_fn" | tail -1)
		grep -q 'emit(callback, 207' <<< "$last" && [[ $(grep -c 'emit(callback, 207' <<< "$install_fn") -eq 1 ]]
	}
	check "Rust 207 is the last callback of a successful install" last_emit_is_207
	check "Rust returns false without starting a worker on bad input" \
		bash -c "awk '/thread::spawn/ {exit} {print}' <<< \"\$1\" | grep -q 'return false' && ! awk '/thread::spawn/ {exit} {print}' <<< \"\$1\" | grep -q 'emit('" _ "$entry"
	IDEVICE_IP=$(ls -d "$HOME"/.cargo/git/checkouts/idevicekit-zag-*/191f36c/idevice/src/services/installation_proxy.rs 2>/dev/null | head -1 || true)
	if [[ -n "$IDEVICE_IP" ]]; then
		watch=$(awk '/async fn watch_completion/ {inside=1} inside {print} inside && /^    }$/ {exit}' "$IDEVICE_IP")
		check "idevice awaits each 206 progress callback inline" \
			bash -c "grep -q 'callback((c, state.clone())).await' <<< \"\$1\" && ! grep -q 'spawn' <<< \"\$1\"" _ "$watch"
	else
		echo "SKIP  idevice crate source not in the cargo cache; 206 inline-await not checked"
	fi
else
	echo "FAIL  Rust installer source missing (initialise the RPPairingCore submodule)"
	FAILURES=$((FAILURES + 1))
fi

# Device-family guard: an iPhone-only build must not replace a native iPad
# installation, and an iPad-only build must not be handed to an iPhone.
validate=$(function_body "$COORD" validateSignedApp)
family_guard_before_team() {
	local guard_line team
	guard_line=$(grep -n 'ZagDeviceFamilyPolicy.allowsReplacement' <<< "$validate" | head -1 | cut -d: -f1)
	team=$(grep -n 'try validateProvisioningTeam' <<< "$validate" | head -1 | cut -d: -f1)
	[[ -n "$guard_line" && -n "$team" && "$guard_line" -lt "$team" ]]
}
check "signed candidates pass the device-family guard" family_guard_before_team
check "guard reads the candidate's own Info.plist" \
	grep -q 'candidate: ZagDeviceFamilyPolicy.families(fromInfoPlistValue: info\["UIDeviceFamily"\])' <<< "$validate"
check "guard compares with the running installation" \
	grep -q 'installed: ZagDeviceFamilyPolicy.families(fromInfoPlistValue: Bundle.main.object(forInfoDictionaryKey: "UIDeviceFamily"))' <<< "$validate"
check "guard uses the hardware model, not the interface idiom" \
	bash -c "grep -q 'device: ZagDeviceFamilyPolicy.currentDevice()' <<< \"\$1\" && ! grep -q 'userInterfaceIdiom' \"\$2\"" _ "$validate" "$ROOT/Feather/Utilities/ZagDeviceFamilyPolicy.swift"
check "device-family mismatch has its own error" grep -q 'throw UpdateError.incompatibleDeviceFamily' <<< "$validate"
for caller in signImportedRelease stageSignedSelfUpdate persistStagedHandoff; do
	check "$caller validates the signed app" grep -q 'try validateSignedApp(signed, release: release)' <<< "$(function_body "$COORD" "$caller")"
done
staged_guard_before_marker() {
	local stage_body v m
	stage_body=$(function_body "$COORD" stageSignedSelfUpdate)
	v=$(grep -n 'try validateSignedApp' <<< "$stage_body" | head -1 | cut -d: -f1)
	m=$(grep -n 'ZagSelfUpdateKeychainProbe.createIfMissing' <<< "$stage_body" | head -1 | cut -d: -f1)
	[[ -n "$v" && -n "$m" && "$v" -lt "$m" ]]
}
check "rejection happens before the keychain marker or pending record" staged_guard_before_marker

if swiftc -warnings-as-errors -parse-as-library \
	"$ROOT/Feather/Utilities/ZagDeviceFamilyPolicy.swift" \
	"$ROOT/scripts/ZagDeviceFamilyPolicyTests.swift" \
	-o "$WORK/family-tests" 2>"$WORK/family-swiftc.log"; then
	if "$WORK/family-tests"; then echo "PASS  device-family policy unit tests"; else FAILURES=$((FAILURES + 1)); fi
else
	cat "$WORK/family-swiftc.log"
	echo "FAIL  device-family policy tests did not compile"
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
