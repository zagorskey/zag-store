#!/usr/bin/env bash
# Self-update download-verification integrity tests on an iOS simulator.
#
# Compiles the real Feather/Utilities/ZagSelfUpdateCoordinator.swift (and the
# self-contained helpers it uses) against scripts/ZagSelfUpdateIntegrityStubs.swift
# into a small simulator app running scripts/ZagSelfUpdateIntegrityTests.swift,
# then installs, runs and removes it. Network access is stubbed. The importer
# itself (AppFileHandler, FR) cannot be compiled here, so source checks below
# confirm it verifies its own working copy, as the stub does.
#
#   SIMULATOR_ID=<udid>   simulator to use (default: first booted iPhone)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-self-update-integrity.XXXXXX")
BUNDLE_ID=local.zagstore.integrity-harness
SIMULATOR_ID="${SIMULATOR_ID:-$(xcrun simctl list devices booted | grep -m1 -oE 'iPhone[^(]*\(([0-9A-F-]{36})\)' | grep -oE '[0-9A-F-]{36}' || true)}"
if [ -z "$SIMULATOR_ID" ]; then
	echo "No booted iPhone simulator; set SIMULATOR_ID" >&2
	exit 2
fi
cleanup() {
	xcrun simctl uninstall "$SIMULATOR_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
	rm -rf "$WORK"
}
trap cleanup EXIT

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
TARGET="$(uname -m)-apple-ios16.4-simulator"
APP="$WORK/IntegrityHarness.app"
mkdir -p "$WORK/modules" "$APP"

U="$ROOT/Feather/Utilities"
REAL=(
	"$U/ZagSelfUpdateCoordinator.swift"
	"$U/ZagUpdateMetadataV2.swift" "$U/ZagUpdateTrustStore.swift" "$U/ZagUpdateRollbackStore.swift"
	"$U/ZagUpdateVerifiedPipeline.swift" "$U/ZagUpdateV2Discovery.swift"
	"$U/ZagDeviceFamilyPolicy.swift" "$U/ZagSelfUpdateRetryPolicy.swift" "$U/ZagSelfUpdateKeychainProbe.swift"
	"$U/ZagMachOSignatureInspector.swift" "$U/ZagLogger.swift" "$U/AnyCodable.swift"
	"$U/ZagPackageIntegrity.swift"
)

# Source checks for code the harness cannot compile or must not contain.
SOURCE_FAILURES=0
source_check() {
	local label="$1"; shift
	if "$@"; then echo "PASS: source: $label"; else echo "FAIL: source: $label"; SOURCE_FAILURES=$((SOURCE_FAILURES + 1)); fi
}
# Print the body of a Swift function (from its signature to the next "func ").
function_body() {
	awk -v name="$2" '
		$0 ~ "func " name "\\(" { inside = 1; print; next }
		inside && /^[[:space:]]*(private |fileprivate |static |@MainActor )*func / { exit }
		inside { print }
	' "$1"
}
HANDLER="$U/Handlers/AppFileHandler.swift"
COORD="$U/ZagSelfUpdateCoordinator.swift"
copy_body=$(function_body "$HANDLER" copy)
verifies_own_copy() {
	local assign verify
	assign=$(grep -n '_ipa = destinationURL' <<< "$copy_body" | head -1 | cut -d: -f1)
	verify=$(grep -n 'ZagPackageIntegrity.verify(_ipa, expectedSHA256:' <<< "$copy_body" | head -1 | cut -d: -f1)
	[[ -n "$assign" && -n "$verify" && "$verify" -gt "$assign" ]]
}
source_check "AppFileHandler verifies its own working copy after copying it" verifies_own_copy
source_check "AppFileHandler extracts that same working copy" \
	grep -q 'Zip.unzipFile(' <(function_body "$HANDLER" extract)
source_check "AppFileHandler extracts self._ipa" grep -q 'self._ipa,' <(function_body "$HANDLER" extract)
source_check "FR.handlePackageFile passes the expected digest to AppFileHandler" \
	grep -q 'AppFileHandler(file: ipa, download: download, expectedSHA256: expectedSHA256)' "$U/FR.swift"
source_check "importPreparedRelease passes the signed SHA-256 to the importer" \
	grep -q 'expectedSHA256: release.sha256' <(function_body "$COORD" importPreparedRelease)
discards_before_download() {
	local body discard download
	body=$(function_body "$COORD" prepare)
	discard=$(grep -n 'discardPreparedIPA()' <<< "$body" | head -1 | cut -d: -f1)
	download=$(grep -n 'downloadVerifiedIPA(release, session: .shared)' <<< "$body" | head -1 | cut -d: -f1)
	[[ -n "$discard" && -n "$download" && "$discard" -lt "$download" ]]
}
source_check "prepare discards earlier prepared state before downloading" discards_before_download
source_check "downloads go to memory, never to a download task's temporary file" \
	bash -c "grep -q 'session.data(from: release.ipaURL)' '$COORD' && ! grep -q 'download(from:' '$COORD'"
source_check "the unsigned local-candidate paths are removed" \
	bash -c "! grep -q -E 'func (prepareLocalIPA|installSelectedLocalCandidate)\\(' '$COORD'"

# Simulator apps carry their entitlements in the binary; the Keychain needs them.
cat > "$WORK/entitlements.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>application-identifier</key><string>HARNESS.$BUNDLE_ID</string>
	<key>keychain-access-groups</key><array><string>HARNESS.$BUNDLE_ID</string></array>
</dict></plist>
PLIST

xcrun --sdk iphonesimulator swiftc -target "$TARGET" -sdk "$SDK" -parse-as-library \
	-module-name IDeviceSwift -emit-module -emit-module-path "$WORK/modules/IDeviceSwift.swiftmodule" \
	-c "$ROOT/scripts/ZagSelfUpdateIntegrityIDeviceSwiftStub.swift" -o "$WORK/IDeviceSwift.o"
xcrun --sdk iphonesimulator swiftc -target "$TARGET" -sdk "$SDK" -parse-as-library \
	-module-name ZagIntegrityHarness -I "$WORK/modules" \
	"${REAL[@]}" "$ROOT/scripts/ZagSelfUpdateIntegrityStubs.swift" "$ROOT/scripts/ZagSelfUpdateIntegrityTests.swift" \
	"$WORK/IDeviceSwift.o" -o "$APP/IntegrityHarness" \
	-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker "$WORK/entitlements.plist"

cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleExecutable</key><string>IntegrityHarness</string>
	<key>CFBundleName</key><string>IntegrityHarness</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0.0</string>
	<key>CFBundleVersion</key><string>2</string>
	<key>MinimumOSVersion</key><string>16.4</string>
	<key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
	<key>DTPlatformName</key><string>iphonesimulator</string>
	<key>UIDeviceFamily</key><array><integer>1</integer></array>
</dict></plist>
PLIST
codesign --force --sign - --timestamp=none "$APP" >/dev/null

xcrun simctl install "$SIMULATOR_ID" "$APP"
xcrun simctl launch --console-pty --terminate-running-process "$SIMULATOR_ID" "$BUNDLE_ID" \
	| tee "$WORK/output.log" | grep -E '^(PASS|FAIL|KNOWN DEFECT|Summary|SUCCESS|FAILED)' || true

if [ "$SOURCE_FAILURES" -eq 0 ] && grep -q '^SUCCESS: self-update integrity checks passed' "$WORK/output.log"; then
	exit 0
fi
grep -q '^FAILED' "$WORK/output.log" || echo "FAIL  harness did not report a result" >&2
exit 1
