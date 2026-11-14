#!/bin/bash
# Focused integrity tests for the real importer. Compiles the unmodified
# AppFileHandler.swift, ZagPackageIntegrity.swift and the real
# FR.handlePackageFile (extracted from FR.swift) for the Mac, with a stub Zip
# module that records the bytes it is asked to extract. No simulator needed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/zag-import-integrity.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/modules"

# The real FR.handlePackageFile, verbatim; the rest of FR.swift needs the
# signing stack.
awk '/static func handlePackageFile\(/ { found = 1 }
	found { print }
	found && /^\t}$/ { exit }' "$ROOT/Feather/Utilities/FR.swift" > "$WORK/body.swift"
grep -q 'AppFileHandler(file: ipa, download: download, expectedSHA256: expectedSHA256)' "$WORK/body.swift" || {
	echo "FAIL  could not extract FR.handlePackageFile" >&2; exit 1
}
{ echo "import Foundation"; echo "enum FR {"; cat "$WORK/body.swift"; echo "}"; } > "$WORK/FRImport.swift"

xcrun swiftc -parse-as-library -module-name Zip -emit-module -emit-module-path "$WORK/modules/Zip.swiftmodule" \
	-c "$ROOT/scripts/ZagImportIntegrityZipStub.swift" -o "$WORK/Zip.o"
xcrun swiftc -parse-as-library -module-name ZagImportIntegrity -I "$WORK/modules" \
	"$ROOT/Feather/Utilities/Handlers/AppFileHandler.swift" \
	"$ROOT/Feather/Utilities/ZagPackageIntegrity.swift" \
	"$ROOT/NimbleKit/Sources/NimbleExtensions/FileManager/FileManager+shortcuts.swift" \
	"$ROOT/NimbleKit/Sources/NimbleExtensions/Bundle/Bundle+keys.swift" \
	"$WORK/FRImport.swift" \
	"$ROOT/scripts/ZagImportIntegrityStubs.swift" "$ROOT/scripts/ZagImportIntegrityTests.swift" \
	"$WORK/Zip.o" -o "$WORK/import-integrity" 2>&1 | grep -E 'error' && exit 1

TMPDIR="$WORK/" "$WORK/import-integrity"
