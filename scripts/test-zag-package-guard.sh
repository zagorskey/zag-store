#!/bin/bash
# Tests the first-launch test-build guard in the canonical packager (ZagStore-Package.zsh)
# by running the packager itself, end to end, WITHOUT the real signing identity and WITHOUT
# touching the canonical IPA:
#
#   - a disposable self-signed "iPhone Distribution" identity in a temporary keychain, and a
#     provisioning profile CMS-signed by it, replace the AppTesters identity and profile;
#   - a copy of the packager differs from the original only in its identity, profile, team,
#     bundle, app-group and OUTPUT constants (checked line by line);
#   - two shims stand in for what a self-signed certificate cannot provide: `security
#     find-identity -v` lists the untrusted test identity, and `codesign -dvv` reports its
#     team (Apple certificates carry it; self-signed ones do not).
#
# The temporary keychain is added to the user's keychain search list while the test runs and
# the original list is restored on exit. Nothing is published.
#
# Usage: scripts/test-zag-package-guard.sh <normal Feather.app> <test-build Feather.app> [packager]
set -euo pipefail

NORMAL_APP=${1:?normal Release Feather.app}
TEST_APP=${2:?first-launch test-build Feather.app (scripts/build-zag-first-launch-test.sh)}
PACKAGER=${3:-"$HOME/Documents/ZagStore-Package.zsh"}
NORMAL_APP=$(cd "$NORMAL_APP" && pwd -P); TEST_APP=$(cd "$TEST_APP" && pwd -P)
CANONICAL="$HOME/Documents/ZagStore-v1.0.0-build1-iOS-AppTesters.ipa"
MARKER=ZAG-FIRST-LAUNCH-TEST-BUILD-NOT-FOR-RELEASE
NAME="iPhone Distribution: Zag Package Test (ZAGTEST001)"
TEAM=ZAGTEST001
BUNDLE=app.zagstore.packagetest
GROUP=group.zagstore.packagetest

WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-package-guard.XXXXXX")
KC="$WORK/test.keychain-db"
ORIGINAL_LIST=$(security list-keychains -d user | tr -d '"' | xargs)
cleanup() {
	# shellcheck disable=SC2086
	security list-keychains -d user -s $ORIGINAL_LIST
	security delete-keychain "$KC" 2>/dev/null || true
	rm -rf "$WORK"
}
trap cleanup EXIT

FAILURES=0
check() {
	local label="$1"; shift
	if "$@"; then echo "PASS  $label"; else echo "FAIL  $label"; FAILURES=$((FAILURES + 1)); fi
}
sha() { if [[ -e "$1" ]]; then shasum -a 256 "$1" | cut -d' ' -f1; else echo absent; fi; }
CANONICAL_BEFORE=$(sha "$CANONICAL")
PACKAGER_BEFORE=$(sha "$PACKAGER")

# Disposable identity and profile.
cd "$WORK"
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 1 \
	-subj "/CN=$NAME/OU=$TEAM" -addext "extendedKeyUsage=codeSigning" \
	-addext "keyUsage=digitalSignature" 2>/dev/null
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -out id.p12 -passout pass:test 2>/dev/null ||
	openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -passout pass:test
rm -f key.pem
security create-keychain -p test "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p test "$KC"
security import id.p12 -k "$KC" -P test -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k test "$KC" >/dev/null
# shellcheck disable=SC2086
security list-keychains -d user -s $ORIGINAL_LIST "$KC"
cat > profile.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>TeamIdentifier</key><array><string>$TEAM</string></array>
<key>Entitlements</key><dict>
<key>application-identifier</key><string>$TEAM.$BUNDLE</string>
<key>com.apple.developer.team-identifier</key><string>$TEAM</string>
<key>keychain-access-groups</key><array><string>$TEAM.*</string></array>
<key>com.apple.security.application-groups</key><array><string>$GROUP</string></array>
</dict></dict></plist>
PLIST
security cms -S -N "$NAME" -k "$KC" -i profile.plist -o test.mobileprovision

# The packager under test: the original with its constants pointed at the test inputs.
OUT="$WORK/out/ZagStore-test.ipa"; mkdir -p "$WORK/out"
python3 -I - "$PACKAGER" "$WORK/packager.zsh" "$WORK/test.mobileprovision" "$NAME" "$TEAM" "$BUNDLE" "$GROUP" "$OUT" <<'PY'
import sys
src, dst, profile, name, team, bundle, group, out = sys.argv[1:]
lines = open(src).read().split("\n")
replace = {
    'PROFILE="': f'PROFILE="{profile}"', "IDENTITY='": f"IDENTITY='{name}'",
    "TEAM_ID='": f"TEAM_ID='{team}'", "BUNDLE_ID='": f"BUNDLE_ID='{bundle}'",
    "EXPECTED_APP_GROUP='": f"EXPECTED_APP_GROUP='{group}'", 'OUTPUT="': f'OUTPUT="{out}"',
}
done = set()
for i, line in enumerate(lines):
    for prefix, new in replace.items():
        if line.startswith(prefix):
            assert prefix not in done, "constant defined twice: " + prefix
            lines[i] = new
            done.add(prefix)
assert done == set(replace), "constants not found: %s" % (set(replace) - done)
open(dst, "w").write("\n".join(lines))
PY
check "packager copy differs only in its six constants" \
	test "$(diff "$PACKAGER" "$WORK/packager.zsh" | grep -c '^>')" = 6

mkdir -p "$WORK/shims"
cat > "$WORK/shims/security" <<SH
#!/bin/bash
if [[ "\$*" == "find-identity -v -p codesigning" ]]; then exec /usr/bin/security find-identity -p codesigning "$KC"; fi
exec /usr/bin/security "\$@"
SH
cat > "$WORK/shims/codesign" <<SH
#!/bin/bash
set -o pipefail
if [[ "\$1" == -dvv ]]; then /usr/bin/codesign "\$@" 2>&1 | sed 's/^TeamIdentifier=not set\$/TeamIdentifier=$TEAM/'; exit; fi
exec /usr/bin/codesign "\$@"
SH
chmod +x "$WORK/shims/security" "$WORK/shims/codesign"

stage() {  # name app -> staging folder holding _build/Applications/Feather.app (a copy)
	mkdir -p "$WORK/$1/_build/Applications"
	ditto "$2" "$WORK/$1/_build/Applications/Feather.app"
	echo "$WORK/$1"
}
package() {  # staging folder -> exit code; log in $WORK/<name>.log
	local status=0
	PATH="$WORK/shims:$PATH" zsh "$WORK/packager.zsh" "$1" > "$WORK/$(basename "$1").log" 2>&1 || status=$?
	return $status
}

# 1. The test build is refused, before anything is signed, and no IPA is written.
check "test build input carries the marker" grep -qaF "$MARKER" "$TEST_APP/Feather"
T=$(stage test "$TEST_APP")
check "test build: packager refuses" bash -c "! PATH='$WORK/shims:$PATH' zsh '$WORK/packager.zsh' '$T' > '$WORK/test.log' 2>&1"
check "test build: refused for the marker" grep -q 'First-launch TEST build' "$WORK/test.log"
check "test build: nothing was signed" bash -c "! grep -q '=== SIGN' '$WORK/test.log'"
check "test build: no IPA written" test ! -e "$OUT"

# 2. The marker anywhere in the bundle (here a framework), not only in the main binary.
H=$(stage hidden "$NORMAL_APP")
fw=$(find "$H/_build/Applications/Feather.app/Frameworks" -type f -perm -u+x | head -1)
chmod u+w "$fw"; printf '%s' "$MARKER" >> "$fw"
check "marker inside a framework: refused" bash -c "! PATH='$WORK/shims:$PATH' zsh '$WORK/packager.zsh' '$H' > '$WORK/hidden.log' 2>&1 && grep -q 'First-launch TEST build' '$WORK/hidden.log'"

# 3. The bundle actually packaged is inspected, whichever folder it comes from (here a
#    staging folder that is not a checkout).
check "normal build input has no marker" bash -c "! grep -rqaF '$MARKER' '$NORMAL_APP'"
N=$(stage normal "$NORMAL_APP")
status=0; package "$N" || status=$?
check "normal build: packaged successfully (exit 0)" test "$status" = 0
check "normal build: both guard checks passed" bash -c "grep -q 'PASS: Not a first-launch test build' '$WORK/normal.log' && grep -q 'PASS: Finished IPA is not a first-launch test build' '$WORK/normal.log'"
check "normal build: IPA written to the test output only" test -s "$OUT"
mkdir -p "$WORK/unpacked"; ditto -x -k "$OUT" "$WORK/unpacked" 2>/dev/null || true
check "normal build: IPA signature verifies" /usr/bin/codesign --verify --deep --strict "$WORK/unpacked/Payload/Feather.app"
check "normal build: IPA has no marker" bash -c "! grep -rqaF '$MARKER' '$WORK/unpacked'"

# 4. A bundle that cannot be read completely is refused (here the packager's copy step stops
#    first; the guard itself also refuses on any search error, grep exit 2).
U=$(stage unreadable "$NORMAL_APP")
cp "$U/_build/Applications/Feather.app/Info.plist" "$U/_build/Applications/Feather.app/zz-unreadable"
chmod 000 "$U/_build/Applications/Feather.app/zz-unreadable"
check "unreadable file in the bundle: refused, nothing signed" bash -c "! PATH='$WORK/shims:$PATH' zsh '$WORK/packager.zsh' '$U' > '$WORK/unreadable.log' 2>&1 && ! grep -q '=== SIGN' '$WORK/unreadable.log'"
chmod 644 "$U/_build/Applications/Feather.app/zz-unreadable"

check "canonical IPA untouched" test "$(sha "$CANONICAL")" = "$CANONICAL_BEFORE"
check "packager untouched by the test" test "$(sha "$PACKAGER")" = "$PACKAGER_BEFORE"

if (( FAILURES > 0 )); then
	echo "$FAILURES test(s) failed (logs: $WORK, removed on exit)"
	for f in "$WORK"/*.log; do echo "== $f"; tail -5 "$f"; done
	exit 1
fi
echo "All packager guard tests passed"
