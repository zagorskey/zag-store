#!/bin/zsh
# Publish a canonical Zag Store IPA (validated locally before any release).
# Usage: zsh scripts/publish-zag-release.zsh nightly /absolute/path/to/canonical.ipa --dry-run
set -euo pipefail

CHANNEL="${1:-}"
IPA="${2:-}"
MODE="${3:---dry-run}"
NOTES_FILE="${4:-}"
[[ "$MODE" == "--dry-run" || "$MODE" == "--publish" ]] || { echo "Third argument must be --dry-run or --publish"; exit 2; }
case "$CHANNEL" in stable|beta|nightly) ;; *) echo "Usage: $0 stable|beta|nightly /absolute/path/to/signed.ipa"; exit 2 ;; esac
[[ -f "$IPA" ]] || { echo "IPA not found: $IPA"; exit 2; }
command -v gh >/dev/null || { echo "GitHub CLI is required"; exit 2; }
command -v python3 >/dev/null || { echo "Python 3 is required"; exit 2; }

if [[ "$MODE" == "--publish" ]]; then
  [[ -n "$NOTES_FILE" && -s "$NOTES_FILE" ]] || { echo "Publishing requires a non-empty notes file as fourth argument"; exit 2; }
fi
REPO="zagorskey/zag-store-releases"
TMP=$(mktemp -d "${TMPDIR:-/tmp/}zag-release.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# Inspect the exact IPA payload, not the Xcode project version.
unzip -q "$IPA" -d "$TMP/unpacked"
APP="$TMP/unpacked/Payload/Feather.app"
[[ -f "$APP/Info.plist" ]] || { echo "Invalid IPA payload"; exit 1; }
# Never publish source code, backup copies or build configuration.
# (Never a first-launch test build: the override is cleared for this check.)
env -u ZAG_ALLOW_FIRST_LAUNCH_TEST_BUILD bash "${0:A:h}/zag-check-bundle-contents.sh" "$IPA"
codesign --verify --deep --strict "$APP"
# A canonical artifact must not embed a customer-specific provisioning profile.
[[ ! -e "$APP/embedded.mobileprovision" ]] || { echo "Canonical IPA contains embedded.mobileprovision; refusing publication"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist")
BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
[[ "$BUNDLE" == "app.zagstore.ios" ]] || { echo "Unexpected bundle identifier: $BUNDLE"; exit 1; }
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
# A previously uploaded release can be resumed, but never overwritten.
# Treat lookup failures other than HTTP 404 as fatal (e.g. auth/network errors).
RELEASE_JSON="$TMP/existing-release.json"
RELEASE_STATUS=0
gh api "repos/${REPO}/releases/tags/${TAG}" >"$RELEASE_JSON" 2>"$TMP/release-lookup-error" || RELEASE_STATUS=$?
if (( RELEASE_STATUS != 0 )); then
  if grep -q 'HTTP 404' "$TMP/release-lookup-error"; then
    rm -f "$RELEASE_JSON"
  else
    cat "$TMP/release-lookup-error" >&2
    echo "Release lookup failed; refusing publication" >&2
    exit 1
  fi
fi
if [[ -f "$RELEASE_JSON" ]]; then
  echo "=== VERIFY EXISTING RELEASE FOR RECOVERY ==="
  python3 - "$RELEASE_JSON" "$ASSET" "$CHANNEL" "$NOTES_FILE" <<'PY'
import json, pathlib, sys
path, asset, channel, notes_file = sys.argv[1:]
release = json.loads(pathlib.Path(path).read_text())
assets = release.get("assets", [])
if release.get("draft") or release.get("prerelease") != (channel != "stable"):
    raise SystemExit("Existing release status/channel mismatch; refusing recovery")
if len(assets) != 1 or assets[0].get("name") != asset or assets[0].get("state") != "uploaded":
    raise SystemExit("Existing release asset mismatch; refusing recovery")
if notes_file:
    notes = pathlib.Path(notes_file).read_text(encoding="utf-8").strip()
    if release.get("body", "").strip() != notes:
        raise SystemExit("Existing release notes mismatch; refusing recovery")
print("Existing release metadata matches")
PY
  mkdir -p "$TMP/existing"
  gh release download "$TAG" --repo "$REPO" --pattern "$ASSET" --dir "$TMP/existing"
  EXISTING_SHA=$(shasum -a 256 "$TMP/existing/$ASSET" | awk '{print $1}')
  [[ "$EXISTING_SHA" == "$SHA" ]] || { echo "Existing IPA checksum mismatch; refusing recovery"; exit 1; }
  echo "PASS: Existing release IPA matches exactly"
fi

git clone --quiet --depth 1 "https://github.com/${REPO}.git" "$TMP/dist"
MANIFEST="$TMP/dist/releases/${CHANNEL}.json"
# A single increasing build sequence across all channels prevents an older
# Stable/Beta/Nightly release from being advertised as a newer installation.
# Version is compared first; build breaks ties within the same version.
check_channel_versions() {
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
}
check_channel_versions

if [[ "$MODE" == "--dry-run" ]]; then
  echo "DRY RUN PASSED: canonical IPA, release identity, existing release recovery checks, and cross-channel version checks."
  echo "No release, asset, or manifest was published."
  exit 0
fi

echo "=== PUBLISHING PUBLIC RELEASE ==="
echo "Publishing a canonical IPA. Verify it contains no customer-specific provisioning profile."
echo "Channel: $CHANNEL | Version: $VERSION ($BUILD) | Minimum iOS: $MIN_IOS"
[[ "$MODE" == "--publish" ]] || { echo "Explicit --publish required"; exit 2; }
echo "=== CREATE OR RESUME RELEASE ASSET ==="
NOTES=$(cat "$NOTES_FILE")
[[ -n "${NOTES//[[:space:]]/}" && ${#NOTES} -le 12000 ]] || { echo "Release notes must contain 1–12000 characters"; exit 2; }
if [[ -f "$RELEASE_JSON" ]]; then
  echo "RECOVERY: Reusing verified existing release; no upload or replacement"
elif [[ "$CHANNEL" == "stable" ]]; then
  gh release create "$TAG" "$IPA" --repo "$REPO" --target main --title "Zag Store $VERSION ($BUILD)" --notes-file "$NOTES_FILE"
else
  gh release create "$TAG" "$IPA" --repo "$REPO" --target main --title "Zag Store $VERSION ($BUILD) — ${CHANNEL:u}" --prerelease --notes-file "$NOTES_FILE"
fi

echo "=== VERIFY PUBLIC ASSET ==="
curl -fLsS --retry 3 -o "$TMP/remote.ipa" "$URL"
REMOTE_SHA=$(shasum -a 256 "$TMP/remote.ipa" | awk '{print $1}')
[[ "$REMOTE_SHA" == "$SHA" ]] || { echo "Remote IPA checksum mismatch; manifest not changed"; exit 1; }

echo "=== REFRESH DISTRIBUTION BEFORE MANIFEST COMMIT ==="
# Re-check all channel versions against the latest main. Never discard local work:
# the manifest is not written until after this fast-forward.
git -C "$TMP/dist" pull --ff-only origin main
check_channel_versions

echo "=== PUBLISH CHANNEL MANIFEST LAST ==="
mkdir -p "$TMP/dist/releases"
python3 - "$MANIFEST" "$VERSION" "$BUILD" "$BUNDLE" "$URL" "$SHA" "$MIN_IOS" "$NOTES_FILE" <<'PY'
import json,sys
path,version,build,bundle,url,sha,min_ios,notes_file=sys.argv[1:]
data={"version":version,"build":build,"bundleIdentifier":bundle,"ipaURL":url,"sha256":sha,"minimumIOSVersion":min_ios,"releaseNotes":open(notes_file,encoding="utf-8").read().strip()}
with open(path,"w") as f: json.dump(data,f,indent=2); f.write("\n")
PY
cd "$TMP/dist"
git add "releases/${CHANNEL}.json"
git -c user.name=ZAGORSKI -c user.email=zagorskey@users.noreply.github.com commit -m "Publish ${CHANNEL} ${VERSION} build ${BUILD}"
git push origin main
echo "=== VERIFY PUBLIC MANIFEST ==="
PUBLIC_MANIFEST="$TMP/public-manifest.json"
curl -fLsS --retry 3 -o "$PUBLIC_MANIFEST" "https://raw.githubusercontent.com/${REPO}/main/releases/${CHANNEL}.json"
python3 - "$PUBLIC_MANIFEST" "$VERSION" "$BUILD" "$BUNDLE" "$URL" "$SHA" "$MIN_IOS" "$NOTES_FILE" <<'PY'
import json, sys
path, version, build, bundle, url, sha, min_ios, notes_file = sys.argv[1:]
with open(path) as f:
    published = json.load(f)
expected = {
    "version": version,
    "build": build,
    "bundleIdentifier": bundle,
    "ipaURL": url,
    "sha256": sha,
    "minimumIOSVersion": min_ios,
    "releaseNotes": open(notes_file, encoding="utf-8").read().strip(),
}
for key, value in expected.items():
    if published.get(key) != value:
        raise SystemExit(f"Public manifest verification failed: {key} does not match the published release")
print("Public manifest verified: all seven release fields match")
PY
echo "SUCCESS: ${CHANNEL} release published"
