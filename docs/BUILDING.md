# Building Zag Store

## Requirements

- macOS with **Xcode 26** and the iOS 26 SDK
- **[Rust](https://rustup.rs)** via rustup. The build script adds the `aarch64-apple-ios` and `aarch64-apple-ios-sim` targets
- Git, with access to the submodules (see [Submodules](#submodules))

## Build

```bash
git clone --recurse-submodules https://github.com/zagorskey/zag-store.git
cd zag-store

bash RPPairingCore/build-rust.sh   # builds ZagRPPairingCore.xcframework
make iphoneos                       # Release build → packages/ZagStore.ipa
```

- `build-rust.sh` compiles the Rust pairing core for device and simulator with an iOS 16.4 deployment target and packages it as an XCFramework. Run it again whenever `RPPairingCore/rust-core` changes.
- `make iphoneos` builds the Release configuration with `CODE_SIGNING_ALLOWED=NO`. It also refuses to package source files, backups or build configuration (`scripts/zag-check-bundle-contents.sh`).

The IPA is **unsigned** (ad-hoc signed frameworks only). Sign it with your own certificate and provisioning profile before installing it. Zag Store itself, or any signing tool you trust, can do this.

## Submodules

| Path | Repository | Licence |
| --- | --- | --- |
| `Zsign` | [zagorskey/Zsign-Zag-Experimental](https://github.com/zagorskey/Zsign-Zag-Experimental), branch `zag-cms-experimental` | MIT |
| `IDeviceKitten` | [zagorskey/IDeviceKit-Zag](https://github.com/zagorskey/IDeviceKit-Zag), branch `zag-ios16.4-v0.1.68-clean`, a fork of [claration/idevicekit](https://github.com/claration/idevicekit) | MIT |

The Rust pairing core also depends on `IDeviceKit-Zag`, pinned by commit in `RPPairingCore/rust-core/Cargo.toml`.

## Tests

Most tests run on the Mac host, without a device. They compile the real Swift sources they cover, together with a small harness:

```bash
bash scripts/test-zag-device-link.sh          # LocalDevVPN detection and RPPairing transport
bash scripts/test-zag-repository-refresh.sh   # repository refresh and reconciliation
bash scripts/test-zag-self-update-recovery.sh # self-update recovery
swift scripts/test-zag-v2-pipeline.swift      # signed update metadata, with a disposable key
python3 -I scripts/test-zag-v2-offline-verifier.py
```

Every `scripts/test-*` file is self-contained and prints `PASS` or `FAIL` for each check. Run the tests for the area you change, and say in your pull request what you ran and on which device and iOS version.

## Repository layout

| Path | Contents |
| --- | --- |
| `Feather/` | The SwiftUI app. The folder keeps its upstream name |
| `Feather/RPPairing/` | Swift side of on-device pairing and installation |
| `Feather/Utilities/Zag*` | Zag Store subsystems: self-update, install jobs, Mobile Data Fix, diagnostics |
| `RPPairingCore/` | Rust pairing core, built on `idevice` |
| `Zsign/` | IPA signing (submodule) |
| `IDeviceKitten/` | Device communication (submodule) |
| `AltSourceKit/`, `NimbleKit/` | Repository models and SwiftUI helpers, from Feather |
| `releases/` | Self-update channel documentation and design records |
| `scripts/` | Tests and release tooling |
| `tools/` | The Mobile Data Toggle Shortcut generator, and the README artwork generator |
| `docs/` | Documentation, design notes and README artwork |

## README artwork

The SVGs in `docs/assets/readme/` are generated from one source, in light and dark, using zagstore.app's design tokens:

```bash
python3 -I tools/readme-artwork/generate.py <icon-light.jpg> <icon-dark.jpg> docs/assets/readme
```

The icon inputs are 384-pixel JPEG exports of `Feather/Resources/Assets.xcassets/AppIcon.appiconset/zagstore.png` and `zagstore_dark.png`.
