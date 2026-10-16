#!/bin/zsh
# Publish a previously signed and verified Zag Store IPA.
# Usage: zsh scripts/publish-zag-release.zsh beta /absolute/path/to/signed.ipa
set -euo pipefail

CHANNEL="${1:-}"
IPA="${2:-}"
case "$CHANNEL" in stable|beta|nightly) ;; *) echo "Usage: $0 stable|beta|nightly /absolute/path/to/signed.ipa"; exit 2 ;; esac
[[ -f "$IPA" ]] || { echo "IPA not found: $IPA"; exit 2; }
command -v gh >/dev/null || { echo "GitHub CLI is required"; exit 2; }
command -v python3 >/dev/null || { echo "Python 3 is required"; exit 2; }

REPO="zagorskey/zag-store-releases"
TMP=$(mktemp -d "${TMPDIR:-/tmp/}zag-release.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# Inspect the exact IPA payload, not the Xcode project version.
unzip -q "$IPA" -d "$TMP/unpacked"
APP="$TMP/unpacked/Payload/Feather.app"
[[ -f "$APP/Info.plist" ]] || { echo "Invalid IPA payload"; exit 1; }
codesign --verify --deep --strict "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist")
BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
[[ "$BUNDLE" == "com.cwd43.gu29" ]] || { echo "Unexpected bundle identifier: $BUNDLE"; exit 1; }
[[ "$BUILD" == <-> ]] || { echo "Build must be numeric"; exit 1; }
[[ "$VERSION" == [0-9]* ]] || { echo "Invalid version"; exit 1; }
SHA=$(shasum -a 256 "$IPA" | awk '{print $1}')
ASSET="${IPA:t}"
TAG="v${VERSION}-${CHANNEL}.build${BUILD}"
URL="https://github.com/${REPO}/releases/download/${TAG}/${ASSET}"

echo "=== RELEASE PREVIEW ==="
printf 'Channel: %s\nVersion: %s\nBuild: %s\nBundle: %s\nSHA-256: %s\nIPA: %s\nTag: %s\n' "$CHANNEL" "$VERSION" "$BUILD" "$BUNDLE" "$SHA" "$IPA" "$TAG"
gh repo view "$REPO" --json visibility --jq '.visibility' | grep -qx PUBLIC || { echo "Distribution repo must be public"; exit 1; }
gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 && { echo "Release tag already exists; refusing overwrite"; exit 1; }

git clone --quiet --depth 1 "https://github.com/${REPO}.git" "$TMP/dist"
MANIFEST="$TMP/dist/releases/${CHANNEL}.json"
if [[ -f "$MANIFEST" ]]; then
  CURRENT=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["build"])' "$MANIFEST")
  CURRENT_VERSION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$MANIFEST")
  python3 - "$VERSION" "$BUILD" "$CURRENT_VERSION" "$CURRENT" <<'PY'
import sys
from itertools import zip_longest
def version(s):
    return tuple(int(x) for x in s.split('.'))
new=(version(sys.argv[1]),int(sys.argv[2]))
old=(version(sys.argv[3]),int(sys.argv[4]))
if new <= old:
    raise SystemExit("Refusing to publish non-increasing version/build")
PY
fi

echo "=== CREATE RELEASE ASSET ==="
if [[ "$CHANNEL" == "stable" ]]; then
  gh release create "$TAG" "$IPA" --repo "$REPO" --target main --title "Zag Store $VERSION ($BUILD)" --notes "Zag Store $VERSION, build $BUILD."
else
  gh release create "$TAG" "$IPA" --repo "$REPO" --target main --title "Zag Store $VERSION ($BUILD) — ${CHANNEL:u}" --prerelease --notes "Zag Store $VERSION, build $BUILD."
fi

echo "=== VERIFY PUBLIC ASSET ==="
curl -fLsS --retry 3 -o "$TMP/remote.ipa" "$URL"
REMOTE_SHA=$(shasum -a 256 "$TMP/remote.ipa" | awk '{print $1}')
[[ "$REMOTE_SHA" == "$SHA" ]] || { echo "Remote IPA checksum mismatch; manifest not changed"; exit 1; }

echo "=== PUBLISH CHANNEL MANIFEST LAST ==="
mkdir -p "$TMP/dist/releases"
python3 - "$MANIFEST" "$VERSION" "$BUILD" "$BUNDLE" "$URL" "$SHA" <<'PY'
import json,sys
path,version,build,bundle,url,sha=sys.argv[1:]
data={"version":version,"build":build,"bundleIdentifier":bundle,"ipaURL":url,"sha256":sha,"minimumIOSVersion":"16.0","releaseNotes":"Bug fixes and performance improvements."}
with open(path,"w") as f: json.dump(data,f,indent=2); f.write("\n")
PY
cd "$TMP/dist"
git add "releases/${CHANNEL}.json"
git -c user.name=ZAGORSKI -c user.email=zagorskey@users.noreply.github.com commit -m "Publish ${CHANNEL} ${VERSION} build ${BUILD}"
git push origin main
echo "=== VERIFY PUBLIC MANIFEST ==="
curl -fLsS --retry 3 "https://raw.githubusercontent.com/${REPO}/main/releases/${CHANNEL}.json"
echo
echo "SUCCESS: ${CHANNEL} release published"
