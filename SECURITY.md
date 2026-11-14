# Security Policy

Zag Store handles signing certificates, private keys and app installation on your device, so we take security reports seriously.

## Reporting a vulnerability

**Please do not report security problems in public issues, discussions or pull requests.**

Report them privately through GitHub: open this repository's **Security** tab and choose **[Report a vulnerability](https://github.com/zagstore/zag-store/security/advisories/new)**. Only the maintainers can see the report. You'll be able to discuss it with them there, and you can be credited in the published advisory.

Please include:

- the Zag Store version and build, and your iOS version and device model;
- what an attacker could do, and the steps to reproduce it;
- logs or screenshots, with personal and signing information removed.

Never send real private keys, `.p12` files, certificate passwords, provisioning profiles or device identifiers. Use test material or describe them instead.

## Supported versions

Zag Store is in public beta. Only the latest beta release receives security fixes.

| Version | Supported |
| --- | --- |
| 1.0.0 Beta 2 (build 2) | ✅ |
| 1.0.0 Beta 1 and earlier | ❌ Install Beta 2 manually ([why](docs/INSTALL.md#updating-zag-store)) |

## Update signing key

Zag Store accepts update information for the Beta channel only when it is signed with this Ed25519 key:

| Key ID | SHA-256 fingerprint of the raw public key |
| --- | --- |
| `zag-v2-2026-b` | `844fe8a9856d5e7ebc09c94f5d73acb8e61fb0d26a40d6533e3d9ee65616efa0` |

The earlier key, `zag-v2-2026-a`, is retired and no longer trusted. If you find update information signed with any other key, or have reason to think this key is compromised, report it as a vulnerability.

## Scope

We are particularly interested in:

- certificate, private key and password handling;
- IPA signing;
- pairing and installation on the device;
- the integrity of in-app updates and signed update metadata;
- parsing of repositories and IPAs;
- the Safari installer and signing service on [zagstore.app](https://zagstore.app), and the reports Zag Store sends to it.

The website's services aren't part of this repository, but reports about them are welcome through the same private channel. Please don't test against them in ways that could affect other users: no load testing, no attempts to reach other people's jobs or data, and no use of certificates that aren't yours.

Problems in upstream projects (for example Feather, Zsign or idevice) should also be reported to those projects.

## Response

We will acknowledge reports as soon as we can and keep you updated while we investigate. Formal response times have not been set yet during the beta.
