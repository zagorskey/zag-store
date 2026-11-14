# Release baseline: Zag Store 1.0.0 Beta 2

This page is the verified baseline for Zag Store 1.0.0 Beta 2. It records what was released, how to check it yourself, how the release compares with a clean build, and which tests pass. Later Beta 2 stabilisation work is measured against it.

Verified on 13 November 2026. [Source provenance](SOURCE-PROVENANCE.md) maps the build to its exact commits.

## Release

| | |
| --- | --- |
| Version | 1.0.0 (build 2) |
| Bundle identifier | `app.zagstore.ios` |
| Minimum OS | iOS and iPadOS 16.4 (on-device pairing needs iOS 17) |
| Release | [`v1.0.0-beta.2`](https://github.com/zagstore/zag-store/releases/tag/v1.0.0-beta.2), tag on `1724a764d71a0a6bcf3d4eefdd7ba3aeaf2cfb93` |
| App source | `a2a2475a1d63706423fa2f5442e4de2cfe1811ec` (later commits on `main` up to the tag change documentation and the Zsign pin only) |
| Unsigned IPA | [`ZagStore-1.0.0-unsigned.ipa`](https://github.com/zagorskey/zag-store-releases/releases/download/v1.0.0-beta.2/ZagStore-1.0.0-unsigned.ipa), 60,786,617 bytes |
| IPA SHA-256 | `5bb93c02230a97f3b4eb2c22e4f98ba15f4c5cf71602c2035de139ed81193cd6` |
| Checksum file | [`ZagStore-1.0.0-unsigned.ipa.sha256`](https://github.com/zagorskey/zag-store-releases/releases/download/v1.0.0-beta.2/ZagStore-1.0.0-unsigned.ipa.sha256) |
| Signature | Ad-hoc. No team identifier, no provisioning profile, no entitlements. Sign it with your own certificate before installing |

The IPA is hosted in [zag-store-releases](https://github.com/zagorskey/zag-store-releases/releases/tag/v1.0.0-beta.2), which is also where the in-app updater downloads it from. The release on this repository links to it rather than holding a second copy.

## Source and dependencies

| Component | Repository | Pinned revision |
| --- | --- | --- |
| App | [zagstore/zag-store](https://github.com/zagstore/zag-store) | `1724a764` (tag `v1.0.0-beta.2`) |
| `Zsign` submodule | [zagorskey/Zsign-Zag](https://github.com/zagorskey/Zsign-Zag) | `ab5791658466abc5ebf43fa329dec308acecb922` (tag `zag-1.0.0-beta.2`) |
| `IDeviceKitten` submodule | [zagorskey/IDeviceKit-Zag](https://github.com/zagorskey/IDeviceKit-Zag) | `47476ac2a220d30fe89c8b12992197d0aaf7d61d` |
| Rust `idevice` crate | [zagorskey/IDeviceKit-Zag](https://github.com/zagorskey/IDeviceKit-Zag) | `191f36cae9b08b21b6610452fb1771880b4eae45`, set in `RPPairingCore/rust-core/Cargo.toml` |
| Swift packages | Public repositories | Pinned in `Feather.xcworkspace/xcshareddata/swiftpm/Package.resolved` |

Every dependency is public and can be cloned without credentials.

## Build toolchain and packaging

| | |
| --- | --- |
| Xcode | 26.5 (17F42), iOS SDK 26.5 (`DTSDKName` `iphoneos26.5`, `DTPlatformBuild` 23F73) |
| Build host | macOS 26.7.2 (25G332) |
| Swift | 6.3.2 |
| Rust | 1.98.1 stable, through `RPPairingCore/build-rust.sh` |
| Packaging | `make iphoneos`: Release configuration, `CODE_SIGNING_ALLOWED=NO`, bundle-content guard, ad-hoc signature, zipped with `ditto` |

The Xcode and SDK values are read from the IPA's `Info.plist`. The IPA doesn't record the Swift or Rust versions; the table gives the versions installed on the release build host.

## Update metadata

Zag Store finds updates through signed metadata, not through this page.

| | |
| --- | --- |
| Beta channel metadata | [`releases/v2/beta.json`](https://raw.githubusercontent.com/zagorskey/zag-store-releases/main/releases/v2/beta.json) in zag-store-releases |
| Format | Schema 2: Ed25519 signature over `ZAG-STORE-UPDATE-V2\n` followed by the payload |
| Signing key | `zag-v2-2026-b` |
| Key fingerprint | `844fe8a9856d5e7ebc09c94f5d73acb8e61fb0d26a40d6533e3d9ee65616efa0` (SHA-256 of the raw 32-byte public key in `Feather/Utilities/ZagUpdateTrustStore.swift`) |
| Sequence at release | 5, valid until 19 November 2026 18:30 UTC |

Metadata expires within seven days and is renewed with a higher sequence number, so the live sequence will be higher than 5 by the time you read this. The app refuses metadata that is expired, has a lower sequence than it has already accepted, or is signed with any other key. The retired key `zag-v2-2026-a` isn't trusted.

## Verify it yourself

Check the IPA:

```sh
curl -LO https://github.com/zagorskey/zag-store-releases/releases/download/v1.0.0-beta.2/ZagStore-1.0.0-unsigned.ipa
shasum -a 256 ZagStore-1.0.0-unsigned.ipa
# 5bb93c02230a97f3b4eb2c22e4f98ba15f4c5cf71602c2035de139ed81193cd6

unzip -q ZagStore-1.0.0-unsigned.ipa -d beta2
for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion MinimumOSVersion; do
  /usr/libexec/PlistBuddy -c "Print $key" beta2/Payload/Feather.app/Info.plist
done
# app.zagstore.ios, 1.0.0, 2, 16.4
codesign -dv beta2/Payload/Feather.app 2>&1 | grep -E 'Identifier|Signature'
# Identifier=app.zagstore.ios, Signature=adhoc
```

Check the source and its submodules:

```sh
git clone --recurse-submodules --branch v1.0.0-beta.2 https://github.com/zagstore/zag-store.git
cd zag-store
git rev-parse HEAD                 # 1724a764d71a0a6bcf3d4eefdd7ba3aeaf2cfb93
git submodule status               # Zsign ab579165…, IDeviceKitten 47476ac2…
git -C Zsign rev-parse 'HEAD^{tree}'   # d2d1add935828466d69ae10c59a0a8433218cb7c
```

Check the live update metadata signature (needs Python with the `cryptography` package):

```sh
python3 - <<'EOF'
import base64, hashlib, json, re, urllib.request
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
src = open("Feather/Utilities/ZagUpdateTrustStore.swift").read()
key = bytes(int(b, 16) for b in re.findall(r"0x([0-9a-fA-F]{2})", src.split('"zag-v2-2026-b"', 1)[1].split("])", 1)[0]))
print("fingerprint", hashlib.sha256(key).hexdigest())
url = "https://raw.githubusercontent.com/zagorskey/zag-store-releases/main/releases/v2/beta.json"
envelope = json.load(urllib.request.urlopen(url))
payload = base64.b64decode(envelope["payload"])
Ed25519PublicKey.from_public_bytes(key).verify(base64.b64decode(envelope["signature"]), b"ZAG-STORE-UPDATE-V2\n" + payload)
p = json.loads(payload)
print("valid:", envelope["keyId"], "sequence", p["sequence"], "build", p["build"], "expires", p["expiresAt"])
EOF
```

Run it from the root of the clone. It raises an error if the signature doesn't verify.

## Clean build comparison

A clean clone of `v1.0.0-beta.2`, built with `bash RPPairingCore/build-rust.sh` and `make iphoneos` using the toolchain above, was compared with the official IPA.

| | Result |
| --- | --- |
| Version, build, bundle identifier, minimum OS | Identical |
| Frameworks, resources, assets, localisations | Identical, byte for byte |
| Main executable | Same size (20,112,672 bytes), different bytes. Builds aren't reproducible: the executable embeds a build UUID and the absolute paths of the build folders. |
| `_CodeSignature/CodeResources` | Different, as a consequence of the executable and acknowledgement files |
| Licence acknowledgements | Same content, different location. See *Known limitations* |
| Entitlements | None in either |

The official IPA was not rebuilt or replaced. It remains the release of record.

## Automated tests

All tests run on a Mac without a device. Results on `1724a764`:

| Suite | How to run | Result |
| --- | --- | --- |
| Background refresh | `bash scripts/test-zag-background-refresh.sh` | ✅ Pass |
| Certificate export disabled | `bash scripts/test-zag-certificate-export-disabled.sh` | ✅ Pass |
| Bundle-content guard | `bash scripts/test-zag-check-bundle-contents.sh` | ✅ Pass |
| First-launch report | `bash scripts/test-zag-first-launch-report.sh` | ✅ Pass |
| Repository refresh | `bash scripts/test-zag-repository-refresh.sh` | ✅ Pass |
| Self-update recovery | `bash scripts/test-zag-self-update-recovery.sh` | ✅ Pass |
| Metadata expiry | `bash scripts/test-zag-v2-expiry.sh` | ✅ Pass |
| Multi-process anti-rollback | `zsh scripts/test-zag-v2-multiprocess.zsh` | ✅ Pass |
| Trust store, verified pipeline, rollback store, actual validator, expiry | `swiftc` with the four `ZagUpdate*` sources (see below) | ✅ Pass |
| Python interop, Python negative cases, discovery integration | Same, with a fixture from `scripts/generate-zag-v2-python-fixture.py` | ✅ Pass |
| JSON canonicality gate | `swift scripts/test-zag-v2-json-gate.swift` | ✅ Pass |
| Offline verifier, public-key preparation, CryptoKit interop | `python3 scripts/<name>.py` | ✅ Pass |
| Device link | `bash scripts/test-zag-device-link.sh` | ⚠️ 2 of 576 checks fail: obsolete assertions |
| Discovery | Swift, with `ZagUpdateV2Discovery.swift` | ⚠️ 1 check fails: obsolete assertion |
| Published Beta discovery | Swift, with the live metadata URL | ⚠️ Fails: obsolete assertion |
| Test vector | `python3 scripts/zag-v2-test-vector.py` | ⚠️ Fails: obsolete fixture |
| Install control taps (UI) | `bash scripts/test-zag-install-control-taps.sh` with a booted iPhone simulator, or `SIMULATOR_ID` set | ✅ Pass, 8 XCUITest cases on iPhone 17 |
| Production-key rehearsal | Needs an envelope signed for the rehearsal, so it can't run against live metadata | Not run |
| Packager guard | Exercises the maintainer's local packaging setup, so it isn't part of the public baseline | Not run |

Compile the standalone Swift metadata tests like this:

```sh
swiftc -parse-as-library -module-name Feather \
  Feather/Utilities/ZagUpdateMetadataV2.swift Feather/Utilities/ZagUpdateTrustStore.swift \
  Feather/Utilities/ZagUpdateRollbackStore.swift Feather/Utilities/ZagUpdateVerifiedPipeline.swift \
  Feather/Utilities/ZagUpdateV2Discovery.swift \
  scripts/test-zag-v2-trust-store.swift -o /tmp/test-zag-v2-trust-store && /tmp/test-zag-v2-trust-store
```

**No failure is a regression in the app.** Every failing check tests an expectation that was true when it was written and has since been intentionally superseded:

- **Device link:**
  - *installer core unchanged* and *Install Preview not part of this phase* compare files against commits from before the history rewrite (`9575060b`, `4b2c3a21`), which don't exist in this repository.
  - The files themselves are unchanged since the equivalent public commits (`cdc94c31`, `45768c76`).
- **Discovery:** *empty production trust* expects the production trust store to be empty. Beta 2 ships the `zag-v2-2026-b` key, so the request goes out instead.
- **Published Beta discovery:** expects sequence 1, build 3 and an earlier IPA checksum. Those values predate Beta 2.
- **Test vector:** its fixture uses an application identifier from before metadata was bound to `app.zagstore.ios`, which the signer now rejects.

Seven Swift test files have no runner: the six `scripts/ZagMetadataV2*Tests.swift` files and `scripts/ZagMetadataV2TestVerifier.swift`. They test standalone October prototypes kept in `scripts/ZagMetadataV2*.swift`, not the shipped `ZagUpdate*` pipeline, which replaced that design. `scripts/ZagVariantLineageResolverTests.swift` also has no runner, but it tests code the app ships.

The repository has no automated CI. The only workflow, `.github/workflows/release.yml`, can only be started manually, and its job is disabled.

## Known limitations

- **Acknowledgements in iOS Settings are empty in this build.** In iOS Settings, *Zag Store → Acknowledgements* opens a pane whose file the official IPA doesn't have where Settings looks for it.
  - The licence texts are inside the IPA, but in `com.mono0926.LicensePlist.Output/` rather than `Settings.bundle/`.
  - The *Copy Acknowledgements* build phase moves them, but in the release build it ran before LicensePlist wrote its output.
  - A clean build places them correctly.
  - The full list is also in [ACKNOWLEDGEMENTS.md](../ACKNOWLEDGEMENTS.md).
- **Builds aren't bit-for-bit reproducible.** The executable embeds absolute build paths and a build UUID.
- **Beta 1 can't update in the app.** It trusts only the retired key. Install Beta 2 manually once; later Betas arrive in the app.
- **Update metadata expires.** It must be renewed at least weekly. If it lapses, the app reports expired update information until it's renewed. It never accepts unsigned or expired metadata.
- **Some tests are out of date.** See *Automated tests*.

## Upcoming maintenance

Beta 2 stabilisation continues in small, separately reviewed pull requests:

1. **Out-of-date tests.** Update the obsolete assertions in the four tests above, and review the seven unreferenced test files to decide whether their coverage should be restored or removed.
2. **Automated checks.** One script that runs every host test, and a GitHub Actions workflow that runs it on pull requests.
3. **Acknowledgements packaging.** Make the *Copy Acknowledgements* step run after LicensePlist, and make packaging fail if the Settings acknowledgements are missing. Consider removing absolute build paths from release binaries.
4. **Public beta documentation.** Bring the release-channel publishing notes in [`releases/README.md`](../releases/README.md) up to date.

Fixes ship in a later Beta. This page continues to describe 1.0.0 Beta 2 (build 2) as released.
