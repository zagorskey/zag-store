#!/bin/bash
# Fail if a Zag Store app bundle or IPA contains files that must never ship:
# source code, editor/backup copies, build configuration, or key material.
#
# Why: Feather/ is an Xcode synchronized folder, so any non-source file placed
# in it is copied into the app by "Copy Bundle Resources" automatically.
#
# Usage: scripts/zag-check-bundle-contents.sh <path/to/App.app | path/to/App.ipa>
set -euo pipefail

TARGET="${1:-}"
if [[ -z "$TARGET" || ! -e "$TARGET" ]]; then
	echo "Usage: $0 <path/to/App.app | path/to/App.ipa>" >&2
	exit 2
fi

# Lower-case file-name patterns (shell globs, matched against the base name).
FORBIDDEN=(
	'*.swift' '*.swift.*' '*.m.*' '*.h.*'
	'*.backup' '*.backup-*' '*-backup' '*.before-*' '*.bak' '*.bak-*' '*.orig' '*.rej' '*~'
	'*.xcconfig' '*.xcconfig.*'
	'*.p12' '*.pem' '*.key' 'server.crt' 'commonname.txt'
)

list_entries() {
	if [[ -d "$TARGET" ]]; then
		(cd "$TARGET" && find . -type f -print | sed 's#^\./##')
	else
		unzip -Z1 "$TARGET"
	fi
}

ENTRIES=$(list_entries) || { echo "Unable to list $TARGET" >&2; exit 2; }
[[ -n "$ENTRIES" ]] || { echo "No files found in $TARGET" >&2; exit 2; }

LEAKS=()
while IFS= read -r entry; do
	[[ -z "$entry" || "$entry" == */ ]] && continue
	name=$(basename "$entry" | tr '[:upper:]' '[:lower:]')
	for pattern in "${FORBIDDEN[@]}"; do
		# shellcheck disable=SC2053
		if [[ "$name" == $pattern ]]; then
			LEAKS+=("$entry")
			break
		fi
	done
done <<< "$ENTRIES"

if (( ${#LEAKS[@]} > 0 )); then
	echo "Forbidden files found in $TARGET (${#LEAKS[@]}):" >&2
	printf '  %s\n' "${LEAKS[@]}" >&2
	echo "Move them out of the Feather/ source folder and rebuild." >&2
	exit 1
fi

echo "Bundle contents check passed: $TARGET"
