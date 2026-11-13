#!/bin/sh
# Installs the official Shortcut page into the static landing site.
# Writes only /var/www/zagstore-landing/shortcuts/mobile-data-fix/ (creating
# shortcuts/ if needed). Never touches the homepage, Nginx or other files.
# Run as root on the website host, from the staged copy of this folder.
set -eu
umask 022
SRC="$(cd "$(dirname "$0")" && pwd)/shortcuts/mobile-data-fix"
DEST=/var/www/zagstore-landing/shortcuts/mobile-data-fix
SHORTCUT="Zag Mobile Data Toggle.shortcut"

# Copy into a private folder first, then verify and install those copies only.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp "$SRC/index.html" "$SRC/$SHORTCUT" "$SRC/SHA256SUMS" "$WORK/"
cd "$WORK"
cat > expected.sha256 <<'SUMS'
f9f1bf5fdc3d6ca2ec7f90c75707e9e76bd78ec2cee79ee055b87341529a9bed  index.html
3f976b56313871fdb2f662593c62a749d54927d23ca14410467005f0a71f81d3  Zag Mobile Data Toggle.shortcut
6cf1d2e7939c330b173768273aae79ac0e1731e12d244019569f584f5ef3ce0b  SHA256SUMS
SUMS
if ! sha256sum -c --strict expected.sha256; then
	echo "Verification failed. Nothing was installed." >&2
	exit 1
fi

install -d -o root -g root -m 755 /var/www/zagstore-landing/shortcuts "$DEST"
install -o root -g root -m 644 index.html "$SHORTCUT" SHA256SUMS "$DEST/"
(cd "$DEST" && sha256sum -c --strict "$WORK/expected.sha256")
ls -l "$DEST"
