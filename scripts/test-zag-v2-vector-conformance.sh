#!/bin/bash
# Runs the Python reference vector against the app's verified update pipeline
# (see test-zag-v2-vector-conformance.swift). Host only, no network; needs
# Python 3 with the cryptography package (set PYTHON to choose the interpreter).
# Usage: bash scripts/test-zag-v2-vector-conformance.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON="${PYTHON:-python3}"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-v2-vector-conformance.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

if ! "$PYTHON" -c 'import cryptography' 2>/dev/null; then
	echo "FAIL  $PYTHON lacks the cryptography package; install it or set PYTHON" >&2
	exit 1
fi
"$PYTHON" "$ROOT/scripts/zag-v2-test-vector.py" > "$WORK/vector.json"
swiftc -parse-as-library -module-name Feather \
	"$ROOT/Feather/Utilities/ZagUpdateMetadataV2.swift" \
	"$ROOT/Feather/Utilities/ZagUpdateTrustStore.swift" \
	"$ROOT/Feather/Utilities/ZagUpdateRollbackStore.swift" \
	"$ROOT/Feather/Utilities/ZagUpdateVerifiedPipeline.swift" \
	"$ROOT/scripts/test-zag-v2-vector-conformance.swift" \
	-o "$WORK/vector-conformance"
"$WORK/vector-conformance" "$WORK/vector.json"
