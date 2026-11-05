# Security Policy

Zag Store handles signing certificates, private keys and app installation on your device, so we take security reports seriously.

## Reporting a vulnerability

**Please do not report security problems in public issues, discussions or pull requests.**

A private reporting channel must be enabled before the public launch. Once GitHub private vulnerability reporting is enabled, use the repository's **Security → Report a vulnerability** option. Until then, do not submit vulnerability details to public issues or discussions. The maintainers are preparing a verified private contact method.

Please include:

- the Zag Store version and build, and your iOS version and device model;
- what an attacker could do, and the steps to reproduce it;
- logs or screenshots, with personal and signing information removed.

Never send real private keys, `.p12` files, certificate passwords, provisioning profiles or device identifiers. Use test material or describe them instead.

## Supported versions

Zag Store is in public beta. Only the latest beta release receives security fixes.

## Scope

We are particularly interested in:

- certificate, private key and password handling;
- IPA signing;
- pairing and installation on the device;
- the integrity of in-app updates;
- parsing of repositories and IPAs.

Problems in upstream projects (for example Feather, Zsign or idevice) should also be reported to those projects.

## Response

We will acknowledge reports as soon as we can and keep you updated while we investigate. Formal response times have not been set yet during the beta.
