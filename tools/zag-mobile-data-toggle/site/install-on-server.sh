#!/bin/sh
# Installs the official Shortcut page into the static landing site.
# Adds only /shortcuts/mobile-data-fix/; changes no other file or Nginx setting.
# Run on zagstore-prod-01 from the staging folder: sudo sh install-on-server.sh
set -eu
SRC="$(cd "$(dirname "$0")" && pwd)/shortcuts/mobile-data-fix"
DEST=/var/www/zagstore-landing/shortcuts/mobile-data-fix
EXPECTED=3f976b56313871fdb2f662593c62a749d54927d23ca14410467005f0a71f81d3
GOT=$(sha256sum "$SRC/Zag Mobile Data Toggle.shortcut" | cut -d' ' -f1)
[ "$GOT" = "$EXPECTED" ] || { echo "Checksum mismatch: $GOT" >&2; exit 1; }
install -d -o root -g root -m 755 /var/www/zagstore-landing/shortcuts "$DEST"
install -o root -g root -m 644 "$SRC/index.html" "$SRC/Zag Mobile Data Toggle.shortcut" "$SRC/SHA256SUMS" "$DEST/"
(cd "$DEST" && sha256sum -c SHA256SUMS)
ls -l "$DEST"
