<div align="center">

# Zag Store

**Your apps. Your certificate. Your way.**

A modern iOS app discovery, signing, and management experience built with SwiftUI.

[Website](https://zagstore.app) · [Download](https://zagstore.app) · [Report an issue](https://github.com/zagorskey/zag-store/issues)

</div>

---

## Meet Zag Store

Zag Store brings app discovery, repository browsing, signing, and installation into a single iOS experience. Explore apps, games, and emulators; manage your sources and certificates; and make the interface your own.

### Highlights

- **Discover more** — Browse apps, games, and emulators with rich artwork and dedicated discovery views.
- **Bring your own certificate** — Sign compatible IPAs with your own signing certificate and provisioning profile.
- **Manage apps** — Install, manage, and update supported apps with integrated activity tracking.
- **Make it yours** — Customisable navigation, themes, app icons, and native-inspired Liquid Glass styling.
- **Repository support** — Browse compatible AltStore-format app sources.
- **In-app updates** — Zag Store includes a self-update workflow for supported configurations.

> **Public beta:** Features, compatibility, and installation requirements may change. Always back up important data before testing pre-release software.

## Get Zag Store

Visit **[zagstore.app](https://zagstore.app)** for the latest public beta and installation instructions.

**Zag Store is distributed as an unsigned IPA.** You must sign it with your own compatible certificate and provisioning profile before installing it. The project does not provide a universal signing certificate.

Installation methods and device capabilities vary with iOS version, provisioning, and signing entitlements. Some local device operations may require a separately installed local VPN utility; see the current beta instructions for details.

Do not upload private keys or certificate passwords to untrusted services.

## Screenshots

Screenshots from the current beta will be added here after release validation. We prefer real device captures over mockups.

## Building from source

This repository contains the Zag Store iOS source and supporting components. Building requires a compatible macOS/Xcode toolchain and the dependencies referenced by the project, including Git submodules.

```bash
git clone --recurse-submodules https://github.com/zagorskey/zag-store.git
cd zag-store
```

Review the project's Makefile and build configuration before running a device build. A usable installed app requires appropriate signing; a locally compiled unsigned artifact is not itself installable on a stock iPhone.

## Open source and attribution

Zag Store builds on the work of the **[Feather](https://github.com/claration/Feather)** project and its contributors. We gratefully acknowledge the upstream authors and the open-source ecosystem supporting iOS signing and device communication.

Key upstream components and projects include:

- [Feather](https://github.com/claration/Feather) — foundational app and signing experience.
- [idevice](https://github.com/jkcoxson/idevice) — device communication.
- [Zsign](https://github.com/zhlynn/zsign) — application signing.
- [Nuke](https://github.com/kean/Nuke) — image loading and caching.

See the repository's dependency declarations and individual component licences for additional attributions. Zag Store is an independent project and is not affiliated with Apple.

## Contributing and security

We welcome constructive feedback, reproducible bug reports, and contributions. Please check existing issues before opening a new one.

**Security issues:** Please avoid posting exploitable vulnerabilities, credentials, private keys, or provisioning profiles in public issues. Contact the maintainers privately through an available private reporting channel.

## Licence

Zag Store is distributed under the **[GNU General Public License v3.0](LICENSE)**, subject to applicable third-party licences and notices. Upstream copyright and attribution notices must be retained.

---

<div align="center">

**Made for people who want more control over their iOS app experience.**

[zagstore.app](https://zagstore.app) · [GitHub Issues](https://github.com/zagorskey/zag-store/issues)

</div>
