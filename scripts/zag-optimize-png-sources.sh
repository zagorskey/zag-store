#!/usr/bin/env bash
# Losslessly recompress repository PNG files; never resize or change source artwork.
# Run from the repository root on macOS. Review the resulting git diff before committing.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
command -v pngcrush >/dev/null || { echo "pngcrush is required (Xcode command line tools)." >&2; exit 1; }
command -v sips >/dev/null || { echo "sips is required." >&2; exit 1; }
before=0; after=0; improved=0; unchanged=0; failed=0
while IFS= read -r -d '' file; do
  bytes=$(stat -f %z "$file")
  before=$((before+bytes))
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp/}zag-png.XXXXXXXX")
  tmp="$tmpdir/optimised.png"
  if pngcrush -q -brute "$file" "$tmp" >/dev/null 2>&1 && [ -s "$tmp" ]; then
    old_dims=$(sips -g pixelWidth -g pixelHeight "$file" 2>/dev/null | tail -2)
    new_dims=$(sips -g pixelWidth -g pixelHeight "$tmp" 2>/dev/null | tail -2)
    new_bytes=$(stat -f %z "$tmp")
    if [ "$old_dims" = "$new_dims" ] && [ "$new_bytes" -lt "$bytes" ]; then
      cat "$tmp" > "$file"
      after=$((after+new_bytes))
      improved=$((improved+1))
      printf 'OPTIMISED %8d -> %8d  %s\n' "$bytes" "$new_bytes" "$file"
    else
      after=$((after+bytes))
      unchanged=$((unchanged+1))
    fi
  else
    after=$((after+bytes))
    failed=$((failed+1))
    printf 'FAILED %s\n' "$file" >&2
  fi
  rm -rf "$tmpdir"
done < <(find Feather Images -type f -iname '*.png' -print0)
printf '\nPNG source bytes: %d -> %d; saved %d bytes\n' "$before" "$after" "$((before-after))"
printf 'Optimised: %d; unchanged: %d; failed: %d\n' "$improved" "$unchanged" "$failed"
echo 'IMPORTANT: Inspect git diff and rebuild to measure Assets.car and IPA size.'
[ "$failed" -eq 0 ]
