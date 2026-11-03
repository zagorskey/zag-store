# Minimal Release size optimisation — reviewed comparison

## Scope and PR #15

This change is stacked on PR #15 (`chatgpt-preview-288-beta`, `b644292cd9ff0acdebcbfc8e019ce3fe9d4f4ee5`), whose parent main is `3efdf71e13bbc8fb48a6cdd0d256d971b4fca7ec`. The new PR changes exactly three files: two Release settings in the Xcode project, a read-only IPA comparison tool, and this report. It adds no artwork, dependency pins, submodule changes or preview scripts. The 288px preview work belongs exclusively to PR #15. The older 512px script is absent. After #15 merges, retarget this PR to main; do not replay #15's commits.

PR #16 stays draft and is superseded by this change. Its mixed local-state snapshot is not carried forward. Its earlier 1,215,643-byte result compared non-equivalent inputs and packaging levels and must not be attributed solely to the two compiler settings.

## Equivalent build inputs

Both new Release builds use the exact PR #15 source, pinned OpenSSL 3.6.3000 and other locked dependencies, the same pinned Zsign/IDeviceKitten source and the same existing Rust static library. Before changing the settings, SHA-256 hashes were recorded for 1,115 source/build inputs, including submodule contents and the static library. After the second build every input matches except `Feather.xcodeproj/project.pbxproj`, whose only diff is:

- `ASSETCATALOG_COMPILER_OPTIMIZATION = space`
- `SWIFT_OPTIMIZATION_LEVEL = "-Osize"`

Both use Xcode 26.5 (17F42), the iPhoneOS 26.5 SDK, Release, generic iOS/arm64, whole-module compilation, `CODE_SIGNING_ALLOWED=NO` and `ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=NO`. The isolated dependency cache was cloned from the existing cache and resolved with `-onlyUsePackageVersionsFromResolvedFile`; neither the existing cache nor the dependency lockfile was upgraded. The selected derived-data directory contains SourcePackages where the existing acknowledgement generator expects it.

Both are packaged with the unmodified `~/Documents/ZagStore-Package.zsh`, project argument `~/Documents/ZagStore-chatgpt`, identical `ZIPOPT=-9`, existing signing identity/profile/entitlements and the script's existing extension handling. The original checkout's build is temporarily staged and restored; original IPAs are never used as output destinations without first preserving and subsequently restoring them. No original IPA, local dirty source, backup directory or existing worktree is discarded.

## New matched signed-IPA comparison

Sizes are exact bytes. These are new baseline and optimised artifacts, not the pair from PR #16.

| Component | Baseline raw | Baseline ZIP | Optimised raw | Optimised ZIP |
|---|---:|---:|---:|---:|
| Asset catalogue | 48,321,752 | 47,919,252 | 47,479,224 | 46,824,932 |
| Embedded frameworks | 5,133,958 | 2,038,382 | 5,133,958 | 2,038,380 |
| Executable | 19,375,776 | 7,038,938 | 18,939,072 | 6,939,983 |
| Other resources and signing | 655,816 | 505,337 | 655,816 | 505,338 |
| Video | 3,353,473 | 3,350,509 | 3,353,473 | 3,350,509 |

ZIP headers/metadata: 20,912 → 20,912 bytes.

IPA: 60,873,330 → 59,680,054 bytes.
Savings: 1,193,276 bytes (1.1380 MiB; 1.9603%).

Baseline SHA-256: `7be807225241b58878f508e7c7ad6a4bf135bdd6df435b4fca14f1b58794505b`

Optimised SHA-256: `2386d50da41947d1a12cb6196bed0ec3c2f8e92bf47ffb0d71e9ae677cf90638`

Both archives passed ZIP CRC verification.

The catalogue and executable account for 1,193,275 compressed bytes of the reduction; the net remaining byte is compressed signature variation. Both ZIP levels are identical, so compression-level changes are not credited to the Release settings. The result is 59.680054 MB and remains above 50 MB.

`Assets.car` remains the dominant component. Xcode's space setting changes its icon storage from LZFSE to lossless ZIP, reducing raw catalogue storage by 842,528 bytes. All 71 catalogue records preserve dimensions, idiom, appearances, colour space, bit depth and other non-storage metadata. All seven Home Screen icon choices retain full-resolution light/dark artwork for phone and pad, plus the primary tinted artwork; the 14 Settings previews remain 288px. No source image is changed by this PR.

The executable is arm64-only and already dead-code stripped. `-Osize` reduces its signed raw size by 436,704 bytes. OpenSSL remains required and arm64-only; its code is byte-identical after excluding signatures. Video and other resources are unchanged. The catalogue's phone/pad icon representations were retained; no device thinning, lossy image/video re-encoding, feature removal or unsupported catalogue rewriting was applied.

## Verification

- Both Release builds succeed with the same locked dependencies.
- Self-update recovery/device-family/retry-policy and background-task/once-completion/identifier/ledger tests pass under both `-O` and `-Osize`.
- Bundle-content regression tests, certificate-export-disabled checks and the built-app bundle guard pass.
- Xcode assetutil validates bitmap index, key format, image blocks and icon size classes.
- Both signed apps pass `codesign --verify --deep --strict --verbose=4`; both ZIPs pass CRC checks.
- The two packages have identical file paths. Every non-code resource, all licence notices, complete Info.plist, embedded provisioning profile and entitlements are identical. Only the executable, catalogue, main CodeResources and the framework's signature differ.
- No GitHub Actions result is claimed: the repository's only workflow is disabled and manual-only. The above checks were run locally.

## Device verification and release gates

On the paired physical iPhone 15 Pro Max (iOS 27.2), both signed builds install as in-place updates and launch successfully. No uninstall or data reset was performed. The currently selected Home Screen icon was retrieved from iOS for each build, was non-placeholder at 1024×1024, and has exactly identical RGBA pixels. This verifies the selected icon, not switching through all seven choices.

The app's performance recording was already enabled. Three process restarts were measured per build after an excluded first launch; app data and caches were retained. Fresh samples were read from the app's existing local metrics, allowing for iOS preference-persistence delay. Baseline runs preceded optimised runs, without cache clearing or controlled network responses. Values below are milliseconds.

| Metric | Baseline runs | Optimised runs | Baseline median | Optimised median |
|---|---|---|---:|---:|
| Launch → Interactive | 5674.73, 5675.98, 5660.85 | 5671.14, 5665.85, 5663.83 | 5674.73 | 5665.85 |
| Launch → Sources | 7079.74, 6744.28, 6955.68 | 6927.21, 6706.72, 6970.36 | 6955.68 | 6927.21 |
| Repositories Refresh | 1404.03, 1067.36, 1278.20 | 1255.13, 1039.88, 1305.47 | 1278.20 | 1255.13 |

No slowdown was observed in these measured launch/refresh medians. This is a smoke comparison, not proof of a general performance improvement: the intentional splash dominates interactive time, refresh depends on network/caches and n=3 is small. The optimised test build remains installed on the iPhone; its existing app data and selected icon were retained.

Full Settings light/dark preview inspection and switching through all seven Home Screen choices remain release gates, distinct from source/catalogue verification. Both the legacy screenshot service and the newer userspace capture service failed to start on the available iPhone; the final native-connection attempt was denied with RemotePairingError 1016 because the iPhone had not been unlocked recently. The paired iPad is locked/disconnected with developer services unavailable, so iPad UI/runtime verification could not be performed. No device passcode, trust, signing or provisioning settings were changed.
 `-Osize` can trade speed for size, so a small launch/refresh timing sample is evidence for review, not a performance guarantee. Keep this PR draft until the remaining device checks and review are complete. Nothing is merged into main.

## Artifacts and reproduction

New matched signed files, both directly in `~/Documents/`:

- `ZagStore-size-review-baseline-20261103.ipa`
- `ZagStore-size-review-optimised-20261103.ipa`

The original `ZagStore-v1.0.0-build1-iOS-AppTesters.ipa`, its preserved baseline copy and `ZagStore-v1.0.0-build1-iOS-AppTesters-optimised-20261103.ipa` from PR #16 remain unchanged. New build/test logs, input manifest, asset inventories and device evidence are retained locally in `/tmp/zag-pr-review`; device preferences and identifiers are not added to Git.

Reproduce the comparison with `python3 scripts/zag-ipa-size-report.py BASELINE.ipa OPTIMISED.ipa`. The tool only reads the two archives, verifies CRCs and reports component sizes and SHA-256 hashes.
