#!/bin/bash
# Regression check: the external certificate-export deep link must stay disabled.
#
# feather://export-certificate?callback_template=... used to send the stored
# P12 and its password to any URL supplied by a web page or another app.
# Checking the callback scheme is not sufficient (any app can register a
# scheme), so the handler and the exporter were removed.
#
# Usage: bash scripts/test-zag-certificate-export-disabled.sh [path/to/Feather.app]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILURES=0

check_absent() {
	local label="$1" pattern="$2"
	local hits
	hits=$(grep -rnF --include='*.swift' -e "$pattern" "$ROOT/Feather/" || true)
	if [[ -n "$hits" ]]; then
		echo "FAIL  $label"
		echo "$hits" | sed 's/^/      /'
		FAILURES=$((FAILURES + 1))
	else
		echo "PASS  $label"
	fi
}

check_absent "no exporter function" "exportCertificateAndOpenUrl"
check_absent "no callback template handling" "callback_template"
check_absent "no certificate placeholder substitution" '$(BASE64_CERT)'
check_absent "no password placeholder substitution" '$(PASSWORD)'

# The handler must still recognise the route so it is consumed, not forwarded.
if grep -qF '"export-certificate"' "$ROOT/Feather/FeatherApp.swift"; then
	echo "PASS  export route is explicitly consumed"
else
	echo "FAIL  export route is no longer explicitly consumed"
	FAILURES=$((FAILURES + 1))
fi

# Optional: inspect a built binary as well.
if [[ $# -ge 1 ]]; then
	BIN="$1/Feather"
	if [[ ! -f "$BIN" ]]; then
		echo "FAIL  binary not found: $BIN"
		FAILURES=$((FAILURES + 1))
	elif strings -a "$BIN" | grep -qx 'callback_template'; then
		echo "FAIL  built binary still contains callback_template handling"
		FAILURES=$((FAILURES + 1))
	else
		echo "PASS  built binary has no callback_template handling"
	fi
fi

if (( FAILURES > 0 )); then
	echo "$FAILURES check(s) failed"
	exit 1
fi
echo "Certificate export link remains disabled"
