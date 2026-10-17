#!/bin/zsh
# Offline diagnostic only. NOT an installation authorization decision.
# Usage: zsh scripts/zag-v2-inspect-ipa.zsh /absolute/path/to/file.ipa
set -euo pipefail
[[ $# -eq 1 ]] || { print -u2 "Usage: $0 /absolute/path/to/file.ipa"; exit 2; }
IPA="$1"
[[ -f "$IPA" && ! -L "$IPA" ]] || { print -u2 "ERROR: Require a regular, non-symlink IPA"; exit 2; }
command -v python3 >/dev/null || { print -u2 "ERROR: Python 3 required"; exit 2; }
command -v codesign >/dev/null || { print -u2 "ERROR: macOS codesign required"; exit 2; }
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-v2-ipa-inspect.XXXXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
# Validate archive member names and reject links before extraction.
python3 - "$IPA" "$WORK" <<'PY'
import pathlib, stat, sys, zipfile
source, output = sys.argv[1:]
root = pathlib.Path(output).resolve()
with zipfile.ZipFile(source) as archive:
    infos = archive.infolist()
    if len(infos) > 20000:
        raise SystemExit("ERROR: Too many archive members")
    total = 0
    seen = set()
    for info in infos:
        name = info.filename
        parts = pathlib.PurePosixPath(name).parts
        if (not name or name.startswith("/") or "\\" in name or
                any(part in ("", ".", "..") for part in parts) or
                any(ord(c) < 32 for c in name) or name in seen):
            raise SystemExit("ERROR: Unsafe or duplicate archive member")
        seen.add(name)
        mode = (info.external_attr >> 16) & 0xFFFF
        if stat.S_ISLNK(mode) or (mode and not (stat.S_ISREG(mode) or stat.S_ISDIR(mode))):
            raise SystemExit("ERROR: Archive links or special files not supported")
        total += info.file_size
        if total > 2 * 1024**3:
            raise SystemExit("ERROR: Uncompressed archive exceeds 2 GiB")
    apps = {name.split("/")[1] for name in seen if
            name.startswith("Payload/") and name.count("/") >= 2 and
            name.split("/")[1].endswith(".app")}
    if len(apps) != 1:
        raise SystemExit("ERROR: Expected exactly one Payload/*.app")
    archive.extractall(root)
    print("PASS: IPA archive extracted for offline inspection")
PY
APP=( "$WORK"/Payload/*.app(N) )
(( ${#APP} == 1 )) || { print -u2 "ERROR: Missing main application"; exit 2; }
print "=== MAIN BUNDLE ==="
plutil -p "$APP[1]/Info.plist"
print "=== MAIN SIGNATURE ==="
codesign --verify --deep --strict --verbose=2 "$APP[1]" 2>&1 || {
    print -u2 "ERROR: Main signature verification failed"; exit 1
}
codesign -dv --verbose=4 "$APP[1]" 2>&1
print "=== MAIN ENTITLEMENTS ==="
codesign -d --entitlements :- "$APP[1]" 2>&1 || true
print "=== NESTED COMPONENTS ==="
find "$APP[1]" -type d \( -name '*.appex' -o -name '*.framework' -o -name '*.app' \) -print
print "SUCCESS: Diagnostic inspection completed; no installation was authorized"
