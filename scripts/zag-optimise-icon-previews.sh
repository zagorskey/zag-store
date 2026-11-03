#!/bin/bash
# Resize only Settings > App Icon preview images to 512x512.
# Does not modify .appiconset sources or any other artwork.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSETS="$ROOT/Feather/Resources/Assets.xcassets"
BACKUP="$ROOT/.zag-icon-preview-backup-$(date +%Y%m%d-%H%M%S)"
NAMES=(
  ZagGBPLight ZagGBPDark
  ZagMatrixLight ZagMatrixDark
  ZagMoneyLight ZagMoneyDark
  ZagNeonFluxLight ZagNeonFluxDark
)
# sips is built into macOS. It writes PNG files without requiring Python packages.
command -v sips >/dev/null || { echo "ERROR: macOS sips not found" >&2; exit 1; }
for name in "${NAMES[@]}"; do
  file="$ASSETS/$name.imageset/$name.png"
  [[ -f "$file" ]] || { echo "ERROR: Missing $file" >&2; exit 1; }
  dims="$(sips -g pixelWidth -g pixelHeight "$file" 2>/dev/null)"
  grep -q 'pixelWidth: 1024' <<< "$dims" || { echo "ERROR: $name is not 1024 pixels wide" >&2; exit 1; }
  grep -q 'pixelHeight: 1024' <<< "$dims" || { echo "ERROR: $name is not 1024 pixels tall" >&2; exit 1; }
done

mkdir -p "$BACKUP"
echo "Backup directory: $BACKUP"
for name in "${NAMES[@]}"; do
  file="$ASSETS/$name.imageset/$name.png"
  cp -p "$file" "$BACKUP/$name.png"
  temp="$(mktemp "${TMPDIR:-/tmp}/zag-preview-XXXXXXXX.png")"
  if ! sips -s format png -z 512 512 "$file" --out "$temp" >/dev/null; then
    rm -f "$temp"
    echo "ERROR: Resize failed for $name; original remains in $BACKUP" >&2
    exit 1
  fi
  dims="$(sips -g pixelWidth -g pixelHeight "$temp" 2>/dev/null)"
  if ! grep -q 'pixelWidth: 512' <<< "$dims" || ! grep -q 'pixelHeight: 512' <<< "$dims"; then
    rm -f "$temp"
    echo "ERROR: Invalid output for $name" >&2
    exit 1
  fi
  mv "$temp" "$file"
  echo "Optimised: $name"
done
echo
echo "Preview optimisation complete. Restore from: $BACKUP"
echo "Installable app icon sources were not changed."
