# Contributing to Zag Store

Thanks for your interest in improving Zag Store.

Please read the [Code of Conduct](CODE_OF_CONDUCT.md) before contributing.

## Guidelines

- Open an issue before undertaking a large architectural change.
- Work on a dedicated feature branch; avoid direct changes to `main`.
- Keep changes focused and include reproducible test results.
- Preserve existing installation, signing, update, and navigation functionality.
- Do not introduce exploits, entitlement bypasses, or certificate harvesting.
- Do not commit certificates, private keys, provisioning profiles, passwords, device identifiers, or internal infrastructure secrets.
- Discuss changes to production endpoints or signing workflows before implementation.
- Respect the licences and notices of Feather, AltSourceKit, NimbleKit, Zsign, and other dependencies.

## Bug reports

Include the Zag Store version, iOS version, device model, steps to reproduce, expected behaviour, and sanitized logs. Remove personal and signing information.

## Building

Clone with submodules:

```bash
git clone --recurse-submodules https://github.com/zagstore/zag-store.git
cd zag-store
```

Then follow [Building Zag Store](docs/BUILDING.md): build the Rust core with `bash RPPairingCore/build-rust.sh`, then run `make iphoneos`. The same page lists the host-run test suites. The resulting `packages/ZagStore.ipa` is ad-hoc signed and must be signed with your own certificate before a stock device will install it.

## Pull requests

- Open pull requests against `main`. Changes reach `main` only through reviewed pull requests.
- Describe what you tested, on which device and iOS version.

## Licensing

Contributions to Zag Store must be compatible with GPL-3.0 and applicable third-party licences. Retain original copyright and attribution notices.
