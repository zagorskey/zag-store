#!/bin/bash
# Optimise only Zag Store Settings > App Icon thumbnails for 96 pt @3x.
# Home Screen icons in *.appiconset are never modified.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSETS="$ROOT/Feather/Resources/Assets.xcassets"
NAMES=(
  ZagOriginalLight ZagOriginalDark
  ZagClearGlassLight ZagClearGlassDark
  ZagFirewoodLight ZagFirewoodDark
  ZagMatrixLight ZagMatrixDark
  ZagMoneyLight ZagMoneyDark
  ZagGBPLight ZagGBPDark
  ZagNeonFluxLight ZagNeonFluxDark
)
command -v sips >/dev/null || { echo "ERROR: macOS sips is required" >&2; exit 1; }
command -v git >/dev/null || { echo "ERROR: git is required" >&2; exit 1; }
[[ -d "$ASSETS" ]] || { echo "ERROR: Missing asset catalog: $ASSETS" >&2; exit 1; }
[[ "$(git -C "$ROOT" rev-parse --show-toplevel)" == "$ROOT" ]] || { echo "ERROR: unexpected repository root" >&2; exit 1; }

# Validate the entire input set before changing a single file.
for name in "${NAMES[@]}"; do
  file="$ASSETS/$name.imageset/$(/usr/bin/python3 - "$ASSETS/$name.imageset/Contents.json" <<'JSONPY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
files = [x["filename"] for x in data["images"] if x.get("filename")]
if len(files) != 1:
    raise SystemExit("Expected exactly one preview image")
print(files[0])
JSONPY
)"
  [[ -f "$file" ]] || { echo "ERROR: Missing preview $file" >&2; exit 1; }
  dims="$(sips -g pixelWidth -g pixelHeight "$file" 2>/dev/null)"
  if ! grep -q 'pixelWidth: 1024' <<< "$dims" || ! grep -q 'pixelHeight: 1024' <<< "$dims"; then
    echo "ERROR: Expected 1024x1024 preview: $file" >&2
    exit 1
  fi
done

backup="$(mktemp -d "${TMPDIR:-/tmp}/zag-preview-originals.XXXXXXXX")"
stage="$(mktemp -d "${TMPDIR:-/tmp}/zag-preview-288.XXXXXXXX")"
echo "Original preview backup: $backup"
echo "Staging resized previews: $stage"

for name in "${NAMES[@]}"; do
  file="$ASSETS/$name.imageset/$(/usr/bin/python3 - "$ASSETS/$name.imageset/Contents.json" <<'JSONPY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
files = [x["filename"] for x in data["images"] if x.get("filename")]
if len(files) != 1:
    raise SystemExit("Expected exactly one preview image")
print(files[0])
JSONPY
)"
  cp -p "$file" "$backup/$name.png"
  sips -s format png -z 288 288 "$file" --out "$stage/$name.png" >/dev/null
  dims="$(sips -g pixelWidth -g pixelHeight "$stage/$name.png" 2>/dev/null)"
  if ! grep -q 'pixelWidth: 288' <<< "$dims" || ! grep -q 'pixelHeight: 288' <<< "$dims"; then
    echo "ERROR: Invalid resized preview $name; source files are unchanged" >&2
    exit 1
  fi
done

# All 14 thumbnails were produced successfully; now replace only those files.
before=0
after=0
for name in "${NAMES[@]}"; do
  file="$ASSETS/$name.imageset/$(/usr/bin/python3 - "$ASSETS/$name.imageset/Contents.json" <<'JSONPY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
files = [x["filename"] for x in data["images"] if x.get("filename")]
if len(files) != 1:
    raise SystemExit("Expected exactly one preview image")
print(files[0])
JSONPY
)"
  old="$(stat -f %z "$file")"
  new="$(stat -f %z "$stage/$name.png")"
  before=$((before + old))
  after=$((after + new))
  cp "$stage/$name.png" "$file"
  printf '%-24s %8d -> %8d bytes\n' "$name" "$old" "$new"
done
echo "Preview PNG source bytes: $before -> $after (saved $((before - after)))"
echo "Home Screen .appiconset files were not changed."
echo "Next: inspect git diff, build once, check Settings thumbnails, and measure IPA."
echo "Restore originals if needed from: $backup"
