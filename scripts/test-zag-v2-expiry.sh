#!/bin/bash
# Expiry regression for signed Beta metadata (see test-zag-v2-expiry.swift).
# With --live, also checks the published Beta manifest with the app's validator
# and production trust store: it must verify and be inside its window.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-v2-expiry.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
SOURCES=(
	"$ROOT/Feather/Utilities/ZagUpdateMetadataV2.swift"
	"$ROOT/Feather/Utilities/ZagUpdateTrustStore.swift"
	"$ROOT/Feather/Utilities/ZagUpdateRollbackStore.swift"
	"$ROOT/Feather/Utilities/ZagUpdateVerifiedPipeline.swift"
)
swiftc -warnings-as-errors -parse-as-library -module-name Feather "${SOURCES[@]}" \
	"$ROOT/scripts/test-zag-v2-expiry.swift" -o "$WORK/test" 2>"$WORK/build.log" \
	|| { cat "$WORK/build.log"; echo "FAIL  build"; exit 1; }
"$WORK/test" || exit 1

[[ "${1:-}" == "--live" ]] || exit 0
cat > "$WORK/live.swift" <<'SWIFT'
import Foundation
@main struct Live {
	static func main() throws {
		let url = URL(string: "https://raw.githubusercontent.com/zagorskey/zag-store-releases/main/releases/v2/beta.json")!
		let data = try Data(contentsOf: url)
		let payload = try ZagUpdateMetadataV2.verifiedPayload(data, trustedKeys: ZagUpdateTrustStore.productionKeys)
		do {
			let p = try ZagUpdateMetadataV2.validatePayload(payload, channel: "beta")
			print("PASS  live Beta manifest: sequence \(p.sequence), \(p.version) (\(p.build)), expires \(p.expiresAt)")
		} catch {
			print("FAIL  live Beta manifest: \(error.localizedDescription)")
			exit(1)
		}
	}
}
SWIFT
swiftc -parse-as-library -module-name Feather "${SOURCES[0]}" "${SOURCES[1]}" "$WORK/live.swift" -o "$WORK/live" 2>"$WORK/live.log" \
	|| { cat "$WORK/live.log"; echo "FAIL  live build"; exit 1; }
"$WORK/live"
