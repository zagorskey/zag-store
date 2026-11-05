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
git clone --recurse-submodules https://github.com/zagorskey/zag-store.git
cd zag-store
```

Review the current Xcode project and Makefile for build requirements. Building an unsigned IPA does not automatically make it installable on a stock device.

## Licensing

Contributions to Zag Store must be compatible with GPL-3.0 and applicable third-party licences. Retain original copyright and attribution notices.
