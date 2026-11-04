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
check "user-facing text makes no unproven cellular claim" absent 'WiFi or Airplane' "$(cat "$ROOT/Feather/Views/Settings/Installation/Tunnel & Pairing/TunnelView.swift")"

if xcrun swiftc -parse-as-library -O "$LINK" "$PROBE" "$ROOT/Feather/Utilities/ZagTransportTrace.swift" "$ROOT/scripts/ZagDeviceLinkTests.swift" \
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
