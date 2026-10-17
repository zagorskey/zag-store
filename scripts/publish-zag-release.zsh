#!/bin/zsh
# Publish a previously signed and verified Zag Store IPA.
# Usage: zsh scripts/publish-zag-release.zsh nightly /absolute/path/to/signed.ipa --dry-run
set -euo pipefail

CHANNEL="${1:-}"
IPA="${2:-}"
MODE="${3:---dry-run}"
[[ "$MODE" == "--dry-run" || "$MODE" == "--publish" ]] || { echo "Third argument must be --dry-run or --publish"; exit 2; }
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
MIN_IOS=$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$APP/Info.plist")
[[ -n "$MIN_IOS" ]] || { echo "Missing MinimumOSVersion"; exit 1; }
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
# A single increasing build sequence across all channels prevents an older
# Stable/Beta/Nightly release from being advertised as a newer installation.
# Version is compared first; build breaks ties within the same version.
python3 - "$TMP/dist/releases" "$VERSION" "$BUILD" <<'PY'
import json, pathlib, re, sys
folder, version, build = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", version):
    raise SystemExit("Version must contain only numeric dot-separated components")
if not re.fullmatch(r"[0-9]+", build):
    raise SystemExit("Build must be a non-negative integer")
def key(v, b):
    parts = tuple(map(int, v.split(".")))
    return parts, int(b)
new = key(version, build)
for channel in ("stable", "beta", "nightly"):
    manifest = folder / (channel + ".json")
    if not manifest.exists():
        continue
    with manifest.open() as handle:
        current = json.load(handle)
    previous = key(str(current["version"]), str(current["build"]))
    if new <= previous:
        raise SystemExit(
            f"Refusing release: {version} ({build}) is not newer than "
            f"{channel} {current['version']} ({current['build']}). "
            "Use a globally increasing version/build."
        )
print("Cross-channel version/build check passed")
PY

if [[ "$MODE" == "--dry-run" ]]; then
  echo "DRY RUN PASSED: signed IPA, release identity, existing tag, and cross-channel version checks."
  echo "No release, asset, or manifest was published."
  exit 0
fi

echo "=== PUBLISHING PUBLIC RELEASE ==="
echo "The signed IPA may expose device-specific provisioning metadata."
echo "Channel: $CHANNEL | Version: $VERSION ($BUILD) | Minimum iOS: $MIN_IOS"
[[ "$MODE" == "--publish" ]] || { echo "Explicit --publish required"; exit 2; }
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
python3 - "$MANIFEST" "$VERSION" "$BUILD" "$BUNDLE" "$URL" "$SHA" "$MIN_IOS" <<'PY'
import json,sys
path,version,build,bundle,url,sha,min_ios=sys.argv[1:]
data={"version":version,"build":build,"bundleIdentifier":bundle,"ipaURL":url,"sha256":sha,"minimumIOSVersion":min_ios,"releaseNotes":"Bug fixes and performance improvements."}
with open(path,"w") as f: json.dump(data,f,indent=2); f.write("\n")
PY
cd "$TMP/dist"
git add "releases/${CHANNEL}.json"
git -c user.name=ZAGORSKI -c user.email=zagorskey@users.noreply.github.com commit -m "Publish ${CHANNEL} ${VERSION} build ${BUILD}"
git push origin main
echo "=== VERIFY PUBLIC MANIFEST ==="
PUBLIC_MANIFEST="$TMP/public-manifest.json"
curl -fLsS --retry 3 -o "$PUBLIC_MANIFEST" "https://raw.githubusercontent.com/${REPO}/main/releases/${CHANNEL}.json"
python3 - "$PUBLIC_MANIFEST" "$VERSION" "$BUILD" "$BUNDLE" "$URL" "$SHA" <<'PY'
import json, sys
path, version, build, bundle, url, sha = sys.argv[1:]
with open(path) as f:
    published = json.load(f)
expected = {
    "version": version,
    "build": build,
    "bundleIdentifier": bundle,
    "ipaURL": url,
    "sha256": sha,
}
for key, value in expected.items():
    if published.get(key) != value:
        raise SystemExit(f"Public manifest verification failed: {key} does not match the published release")
print("Public manifest verified: version, build, bundle, URL and SHA-256 match")
PY
echo "SUCCESS: ${CHANNEL} release published"
