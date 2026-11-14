#!/bin/bash
# Variant lineage, release selection and recent-completion tests for
# ZagVariantLineageResolver (host, no network).
# Usage: bash scripts/test-zag-variant-lineage.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-variant-lineage-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

swiftc -parse-as-library \
	"$ROOT/Feather/Utilities/ZagVariantLineageResolver.swift" \
	"$ROOT/scripts/ZagVariantLineageResolverTests.swift" \
	-o "$WORK/variant-lineage-tests"
"$WORK/variant-lineage-tests"
