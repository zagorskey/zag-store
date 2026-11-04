#!/bin/bash
# Local VPN detection and RPPairing transport checks. Source checks guard the
# wiring; the behavioural tests compile the real device-link and probe code
# on the host and run the probe against a fake lockdown server on 127.0.0.1.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-device-link-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
FAILURES=0

check() {
	local label=$1; shift
	if "$@" >/dev/null 2>&1; then echo "PASS  $label"; else echo "FAIL  $label"; FAILURES=$((FAILURES + 1)); fi
}
absent() { ! grep -qF -- "$1" <<< "$2"; }

TABBAR="$ROOT/Feather/Views/TabView/VariedTabbarView.swift"
CORE="$ROOT/Feather/RPPairing/ZagRPPairingCore.swift"
LINK="$ROOT/Feather/Utilities/ZagDeviceLink.swift"
PROBE="$ROOT/Feather/Utilities/ZagLockdownProbe.swift"
SELFUPDATE="$ROOT/Feather/Utilities/ZagSelfUpdateCoordinator.swift"
MONITOR="$ROOT/Feather/Utilities/ZagLocalVPNMonitor.swift"
monitor=$(cat "$MONITOR")

check "indicator checks the RemotePairing endpoint the transport uses" grep -q 'ZagEndpointProbe.connect()' <<< "$monitor"
check "legacy lockdown QueryType is only used for the report" test "$(grep -c 'ZagLockdownProbe.query()' <<< "$monitor")" = 1
check "legacy lockdown result never reaches the status model" absent 'legacy' "$(sed -n '/private func finishProbe/,/^	}/p' "$MONITOR")"
check "indicator serialises probes through the scheduler" grep -q 'scheduler.request()' <<< "$monitor"
check "indicator runs a queued re-check when a probe ends" grep -q 'outcome.next' <<< "$monitor"
check "path changes are debounced, not dropped" grep -q 'func pathChanged' <<< "$monitor"
check "indicator has no fixed repeating timer" absent 'Timer.scheduledTimer' "$monitor"
check "indicator stops probing when inactive" grep -q 'scheduler.cancel()' <<< "$monitor"
check "indicator skips probes while a real session owns the transport" grep -q 'isTransportBusy' <<< "$monitor"
check "indicator never runs an RPPairing handshake" absent 'zag_' "$monitor"
check "installs publish readiness" test "$(grep -c 'publishReadiness(.verified(Date()))' "$CORE")" = 1
check "health checks publish readiness only through the endpoint guard" test "$(grep -c 'publishGate2Readiness(.verified(Date()))' "$CORE")" = 2
check "the readiness guard checks the endpoint" grep -q 'guard gate2Endpoint.publishesReadiness else { return }' "$CORE"
check "loopback is requested only from the diagnostics screen" test "$(grep -rl 'loopbackExperimental' "$ROOT/Feather" | grep -v ZagDeviceLink.swift)" = "$ROOT/Feather/Views/Settings/Installation/InstallationView.swift"
check "no production call site uses the loopback address" bash -c "! grep -rn '127\.0\.0\.1' '$ROOT/Feather' | grep -v 'ZagDeviceLink.swift\|ZagTransportTrace.swift'"
check "installs, inventory and self-update keep the LocalDevVPN address" bash -c "! grep -rnE 'installGate4IPA|refreshInstalledApps|uninstall' '$ROOT/Feather' | grep -q 'loopback'"
check "health checks default to LocalDevVPN" grep -q 'func startGate2Probe(endpoint: ZagRPPairingEndpoint = .localDevVPN)' "$CORE"
check "the endpoint is fixed only after the running-check guard" bash -c "sed -n '/func startGate2Probe(endpoint/,/^	}/p' '$CORE' | awk '/guard !isGate2Running/{g=NR} /gate2Endpoint = endpoint/{e=NR} END{exit !(g && e && g<e)}'"
check "a queued check keeps its own endpoint" grep -q 'startGate2Probe(endpoint: endpoint)' "$CORE"
check "no global mutable endpoint override" absent 'static var' "$(sed -n '/enum ZagRPPairingEndpoint/,/^}/p' "$LINK")"
check "toolbar has no private probe of its own" absent 'NWConnection' "$(cat "$TABBAR")"
for file in "$TABBAR" "$LINK" "$PROBE" "$CORE" "$MONITOR"; do
	name=$(basename "$file")
	check "$name has no Wi-Fi-only interface requirement" absent 'requiredInterfaceType' "$(cat "$file")"
	check "$name has no SSID dependency" absent 'NEHotspotNetwork' "$(cat "$file")"
done
check "probe uses default TCP parameters (any interface)" grep -q 'using: .tcp' "$PROBE"
check "probe always cancels its connection" grep -q 'connection.cancel()' "$PROBE"
check "toolbar keeps the three-line LOCAL / VPN / status layout" bash -c "grep -q 'Text(\"LOCAL\")' '$TABBAR' && grep -q 'Text(\"VPN\")' '$TABBAR' && grep -q 'Text(statusText)' '$TABBAR'"
check "Gate4 classifies failures before deciding on a retry" grep -q 'ZagRPPairingFailure.classify(message, installationStarted: installationStarted)' "$CORE"
check "Gate4 never retries once installation has begun" grep -q 'gate4InstallationCodes: Set<Int32> = \[205, 206, 208, 209, 210\]' "$CORE"
check "Gate4 retries are opt-in" grep -q 'retryTransientFailures: Bool = false' "$CORE"
check "self-update does not opt in to retries" absent 'retryTransientFailures' "$(cat "$SELFUPDATE")"
forget=$(sed -n '/func forgetPairing() throws {/,/^	}/p' "$CORE")
gate4=$(sed -n '/fileprivate func receiveGate4(/,/^	}/p' "$CORE")
check "the pairing file is deleted in exactly one place" test "$(grep -c 'removeItem(at: Self.pairingFileURL' "$CORE")" = 1
check "that place is the explicit Forget Pairing action" grep -q 'removeItem(at: Self.pairingFileURL' <<< "$forget"
check "Gate4 failures never forget or rewrite pairing" bash -c "! grep -qE 'forgetPairing|pairingFileURL' <<< \"\$1\"" _ "$gate4"
TRACE="$ROOT/Feather/Utilities/ZagTransportTrace.swift"
check "trace sends no data on any connection" absent '.send(' "$(cat "$TRACE")"
check "trace uses no private socket options" bash -c "! grep -qE 'SO_RESTRICT|IP_BOUND_IF|setsockopt' '$TRACE'"
check "trace never reads pairing credentials" absent 'pairingFile' "$(cat "$TRACE")"
check "trace never starts an RPPairing session" absent 'zag_' "$(cat "$TRACE")"
RUST="$ROOT/RPPairingCore/rust-core/src/lib.rs"
session=$(sed -n '/^async fn with_zag_device_session_mode/,/^}/p' "$RUST")
production=$(awk '/SessionMode::Production => \{/{f=1} /SessionMode::Diagnostic => \{/{f=0} f' <<< "$session")
diagnostic=$(awk '/SessionMode::Diagnostic => \{/{f=1} f&&/^    }$/{f=0} f' <<< "$session")
check "rust: production sessions still use rpc.connect" grep -q 'rpc.connect(&mut pairing_file' <<< "$production"
check "rust: production sessions still persist verified credentials" grep -q 'write_to_file(pairing_path)' <<< "$production"
check "rust: credentials are written in exactly one place in the session" test "$(grep -c 'write_to_file' <<< "$session")" = 1
check "rust: diagnostic sessions never write credentials" absent 'write_to_file' "$diagnostic"
check "rust: diagnostic sessions have no pair-setup fallback" bash -c "! grep -qE '\.pair\(|rpc\.connect' <<< \"\$1\"" _ "$diagnostic"
check "rust: diagnostic handshake and pair-verify are separate steps" bash -c "grep -q 'attempt_pair_verify()' <<< \"\$1\" && grep -q 'validate_pairing(&mut verify_copy)' <<< \"\$1\"" _ "$diagnostic"
check "rust: pair-verify uses a copy of the credentials" grep -q 'let mut verify_copy = pairing_file.clone();' <<< "$diagnostic"
check "rust: the default session wrapper is production" grep -q 'SessionMode::Production, progress, operation' "$RUST"
check "rust: only the health check uses diagnostic mode" test "$(grep -c 'SessionMode::Diagnostic,' "$RUST")" = 1
check "rust: the health check is the diagnostic caller" bash -c "sed -n '/^async fn run_gate2_probe/,/^}/p' '$RUST' | grep -q 'SessionMode::Diagnostic,'"
check "rust: handshake completion maps to callback 114" bash -c "sed -n '/^async fn run_gate2_probe/,/^}/p' '$RUST' | grep -q '6 => 114'"
check "swift: callback 114 is recorded as a stage" grep -q 'case 114: stage = "Handshake completed; Pair-Verify started"' "$CORE"
check "rust: error detail never prints debug payloads" absent '{error:?}' "$(sed -n '/^fn error_detail/,/^}/p' "$RUST")"
control=$(grep -A4 'let control: Box<dyn idevice::ReadWrite> = if diagnostic {' <<< "$session")
check "rust: only diagnostic sessions trace the control socket" grep -q 'Box::new(TracedStream::new(stream, wire.clone()))' <<< "$(sed -n 2p <<< "$control")"
check "rust: production sessions keep the plain socket" grep -q 'Box::new(stream)' <<< "$(sed -n 4p <<< "$control")"
check "rust: the wire log never formats buffer contents" bash -c "! sed -n '/^struct TracedStream/,/^fn wire_summary/p' '$RUST' | grep -qE 'from_utf8|\{data|\{buf|filled\(\)\[|:\?\}\", data|hex'"
check "swift: idle checks send nothing" bash -c "! sed -n '/static func idle(/,/^	}/p' '$TRACE' | grep -q 'send('"
APP="$ROOT/Feather/FeatherApp.swift"
CTRL="$ROOT/Feather/Utilities/ZagMobileDataToggleController.swift"
FIXVIEW="$ROOT/Feather/Views/Settings/Installation/ZagMobileDataFixView.swift"
check "toggle: callbacks are handled before existing routing" bash -c "sed -n '/private func _handleURL/,/^	}/p' '$APP' | awk '/ZagMobileDataToggleController.shared.handle/{a=NR} /ZagStoreRouter.open/{b=NR} END{exit !(a && b && a<b)}'"
check "toggle: the router has no shortcut route" absent 'shortcut-callback' "$(cat "$ROOT/Feather/Utils/ZagStoreRouter.swift")"
check "toggle: launched with the public UIApplication.open API" grep -q 'UIApplication.shared.open(url, options: \[:\])' "$CTRL"
check "toggle: no private Settings URL schemes" bash -c "! grep -rqE 'App-Prefs:|prefs:root' '$ROOT/Feather'"
check "toggle: never touches installation, signing or self-update" bash -c "! grep -qE 'installGate4IPA|SigningHandler|ArchiveHandler|ZagSelfUpdate' '$CTRL' '$FIXVIEW'"
check "toggle: off is confirmed by the health check, not the callback" grep -q 'core.startGate2Probe()' "$CTRL"
check "toggle: on is confirmed by the network path" grep -q 'physicalNetworks.contains("Cellular")' "$CTRL"
check "toggle: no automatic retries" bash -c "[ \$(grep -c 'UIApplication.shared.open(url' '$CTRL') -eq 1 ]"
check "toggle: the temporary launch test is gone" bash -c "[ ! -e '$ROOT/Feather/Utilities/ZagShortcutLaunchTest.swift' ] && ! grep -rq 'ZagShortcutLaunchTest' '$ROOT/Feather'"
check "toggle: Settings row uses the approved labels" bash -c "grep -q 'Enable app installation over Mobile Data' '$FIXVIEW' && ! grep -rqi 'cellular installation' '$ROOT/Feather' && grep -q '\"Mobile Data Fix\"' '$FIXVIEW'"
check "toggle: completions are saved to the stored record" grep -q 'update { \$0 = Toggle.record(\$0, after: completion) }' "$CTRL"
check "toggle: Last Verified is absolute, never relative" bash -c "grep -q 'at.formatted(date: .abbreviated, time: .shortened)' '$FIXVIEW' && ! grep -qE 'style: \\.(relative|timer|offset)|RelativeDateTimeFormatter|doesRelativeDateFormatting' '$FIXVIEW'"
check "toggle: the app has one setup URL, under /shortcuts/" bash -c "[ \$(grep -rho 'https://zagstore.app/[a-z/-]*' '$ROOT/Feather' | sort -u | grep -c mobile-data-fix) -eq 1 ] && grep -q 'https://zagstore.app/shortcuts/mobile-data-fix/' '$ROOT/Feather/Utilities/ZagMobileDataToggle.swift' && ! grep -rqE 'zagstore.app/mobile-data-fix|icloud.com/shortcuts|\.shortcut\"' '$ROOT/Feather'"
check "toggle: user-facing text says Mobile Data, not Cellular Data" bash -c "! grep -n 'Cellular Data' '$CTRL' '$FIXVIEW' '$ROOT/Feather/Utilities/ZagMobileDataToggle.swift' && ! grep -n 'Cellular Data' '$ROOT/Feather/Views/Settings/Installation/InstallationView.swift'"
check "toggle: no Verification Failed label remains" bash -c "! grep -rn 'Verification Failed' '$ROOT/Feather'"
COORD="$ROOT/Feather/Utilities/ZagMobileDataInstallCoordinator.swift"
for f in Feather/Views/Sources/Apps/DownloadButtonView.swift Feather/Views/Library/LibraryCellView.swift Feather/Views/Library/LibraryView.swift Feather/Views/Library/Install/InstallPreviewView.swift; do
	check "install: $(basename $f) installs through Mobile Data Fix" grep -q 'ZagMobileDataInstallCoordinator.shared.install(jobID:' "$ROOT/$f"
done
check "install: installGate4IPA and the installer core are unchanged" bash -c "cd '$ROOT' && git diff --quiet 9575060b -- Feather/RPPairing/ZagRPPairingCore.swift"
check "install: self-update never uses Mobile Data Fix" bash -c "! grep -q 'ZagMobileDataInstall' '$ROOT/Feather/Utilities/ZagSelfUpdateCoordinator.swift' && grep -q 'if isSelfInstall {' '$ROOT/Feather/Views/Library/Install/InstallPreviewView.swift'"
check "install: diagnostics installs stay direct" bash -c "! grep -q 'ZagMobileDataInstallCoordinator.shared.install' '$ROOT/Feather/Views/Settings/Installation/InstallationView.swift'"
check "install: no background execution is requested" bash -c "! grep -qE 'beginBackgroundTask|BGTaskScheduler' '$COORD' '$ROOT/Feather/Utilities/ZagMobileDataInstallFlow.swift'"
check "install: consent text is exact" bash -c "grep -q 'Mobile Data Installation' '$ROOT/Feather/Views/Settings/Installation/ZagMobileDataInstallOverlay.swift' && grep -q 'Zag Store needs to temporarily turn off Mobile Data to install this app. It will restore your connection when installation finishes.' '$ROOT/Feather/Views/Settings/Installation/ZagMobileDataInstallOverlay.swift' && grep -q 'Allow Automatically' '$ROOT/Feather/Views/Settings/Installation/ZagMobileDataInstallOverlay.swift'"
check "install: perform never repeats or queues a command" bash -c "grep -q 'guard !isBusy, waiter == nil else { return .handOffRejected }' '$CTRL'"
check "toggle: row lives in Installation Settings" grep -q 'ZagMobileDataFixRow()' "$ROOT/Feather/Views/Settings/Installation/InstallationView.swift"
check "rust: IDeviceKit stays pinned at 191f36ca" grep -q 'rev = "191f36cae9b08b21b6610452fb1771880b4eae45"' "$ROOT/RPPairingCore/rust-core/Cargo.toml"
check "rust: Cargo.lock is unchanged" git -C "$ROOT" diff --quiet HEAD -- RPPairingCore/rust-core/Cargo.lock RPPairingCore/rust-core/Cargo.toml
check "user-facing text makes no unproven cellular claim" absent 'WiFi or Airplane' "$(cat "$ROOT/Feather/Views/Settings/Installation/Tunnel & Pairing/TunnelView.swift")"

if xcrun swiftc -parse-as-library -O "$LINK" "$PROBE" "$ROOT/Feather/Utilities/ZagTransportTrace.swift" "$ROOT/Feather/Utilities/ZagMobileDataToggle.swift" "$ROOT/Feather/Utilities/ZagMobileDataInstallFlow.swift" "$ROOT/scripts/ZagDeviceLinkTests.swift" \
	-o "$WORK/tests" 2>"$WORK/swiftc.log"; then
	if perl -e 'alarm 120; exec @ARGV' "$WORK/tests"; then echo "PASS  device link behaviour tests"; else FAILURES=$((FAILURES + 1)); fi
else
	cat "$WORK/swiftc.log"
	echo "FAIL  device link tests did not compile"
	FAILURES=$((FAILURES + 1))
fi

if (( FAILURES > 0 )); then
	echo "$FAILURES check(s) failed"
	exit 1
fi
echo "Device link checks passed"
