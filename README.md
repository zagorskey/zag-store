<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/zag-store-icon-dark.png">
  <img src="docs/assets/zag-store-icon.png" width="144" alt="Zag Store icon">
</picture>

# Zag Store

### A different kind of app store for iOS.

**Discover beautifully. Sign independently. Make it yours.**

A native SwiftUI experience for exploring apps, games and emulators, managing sources, and signing apps with your own certificate.

[**Explore the website**](https://zagstore.app) · [**Releases**](https://github.com/zagorskey/zag-store/releases) · [**Contribute**](CONTRIBUTING.md)

</div>

---

## Designed to feel at home on iOS

Zag Store isn't just a list of IPA files. It's a complete app experience, shaped around discovery, control and the details that make everyday use feel effortless.

| **Explore** | **Personalise** | **Stay in control** |
| :--- | :--- | :--- |
| Discover apps, games and emulators with artwork, search and dedicated browsing experiences. | Choose your navigation tabs, switch colour themes and enjoy a Liquid Glass-inspired interface on supported iOS versions. | Bring your own signing identity, organise sources, follow installation activity and manage compatible apps. |

### A closer look

> **Real screenshots are being prepared from the current beta.** We won't substitute mockups or outdated Feather captures for the actual Zag Store interface.

**01 — Discover what’s next**

Browse beyond a plain repository list. Explore featured content, dedicated Apps and Games experiences, and compatible AltStore-format sources.

**02 — Your certificate. Your choice.**

Use your own compatible certificate and provisioning profile to sign IPAs. Zag Store does not supply a shared signing identity.

**03 — A dock that adapts to you.**

Keep your preferred destinations close with configurable navigation. The interface offers multiple colour themes and system-inspired visual treatments.

**04 — Everything in one place.**

Manage sources and certificates, follow activity, and use supported update and installation workflows without jumping between unrelated interfaces.

---

## Get Zag Store

**Public beta preparation is underway.** The release package and its SHA-256 checksum are being verified before a distribution build is recommended. Older beta release assets may not meet the intended distribution requirements.

Zag Store is intended for users who provide their **own compatible signing certificate and provisioning profile**. An IPA that lacks a usable developer signature must be signed appropriately before installation on a stock iPhone or iPad.

[**View GitHub releases**](https://github.com/zagorskey/zag-store/releases) · [**Report a bug**](https://github.com/zagorskey/zag-store/issues/new/choose)

**Before installing**

- Check the release notes for the supported iOS versions and installation prerequisites. The project currently targets iOS 16.4 or later; some interface features require iOS 26.
- Use a verified distribution artifact and compare its SHA-256 checksum against the published release value.
- Sign with your own certificate and matching provisioning profile using a signing tool you trust.
- Some device installation and pairing operations require a pairing file and a local VPN utility, depending on the workflow.

Never publish or share your private key, certificate password or provisioning profile in a GitHub issue.

## Build from source

Building requires macOS, a compatible Xcode toolchain (currently Xcode 26), Rust and the project's submodules.

```bash
git clone --recurse-submodules https://github.com/zagorskey/zag-store.git
cd zag-store

bash RPPairingCore/build-rust.sh
make iphoneos
```

> **Source-build availability:** The Zsign submodule currently requires an access change before an unauthenticated public clone can resolve every dependency. Do not treat the above as a verified public build until that is resolved.

Inspect the resulting IPA and its signing metadata before distributing it. A locally built or ad-hoc-signed IPA is not automatically installable on a stock device.

<details>
<summary><strong>Repository structure</strong></summary>

| Path | Purpose |
| --- | --- |
| `Feather/` | SwiftUI application; upstream folder name retained |
| `RPPairingCore/` | Rust device communication and pairing core |
| `Zsign/` | IPA signing submodule |
| `IDeviceKitten/` | Device communication submodule |
| `AltSourceKit/`, `NimbleKit/` | Repository models and interface components |
| `scripts/` | Build, verification and release tooling |

</details>

---

## Built on open source

Zag Store is an independent fork of [Feather](https://github.com/claration/Feather). The original authors and contributors made this project possible, and their copyright notices and applicable licences remain in place.

The project also uses [idevice](https://github.com/jkcoxson/idevice), [Zsign](https://github.com/zhlynn/zsign), [Nuke](https://github.com/kean/Nuke), [ElleKit](https://github.com/evelyneee/ellekit), OpenSSL and other third-party components. Individual components retain their respective licences and notices. Zag Store is not affiliated with Apple or the Feather maintainers.

**Licence:** [GNU GPL v3.0](LICENSE) for Zag Store, subject to applicable third-party licences.

## Help shape what's next

Thoughtful bug reports, design feedback and contributions are welcome.

[**Contributing guide**](CONTRIBUTING.md) · [**Code of Conduct**](CODE_OF_CONDUCT.md) · [**Security policy**](SECURITY.md) · [**Changelog**](CHANGELOG.md)

<div align="center">

---

**Zag Store** · Crafted for a more personal iOS app experience.

[zagstore.app](https://zagstore.app)

</div>
