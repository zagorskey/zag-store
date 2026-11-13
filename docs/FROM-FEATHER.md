# From Feather to Zag Store

Zag Store began as a fork of **[Feather](https://github.com/claration/Feather)**, the on-device signing and installation app created by [Samara (claration)](https://github.com/claration) and its contributors. This page describes what Zag Store inherited, what it rebuilt and what it added. Every comparison is checked against source code, not marketing.

## Method

| | |
| --- | --- |
| **Fork point** | `4db3efff` "bump to v2.9.0", Feather **v2.9.0**, 4 July 2026 |
| **Feather compared at** | v2.9.0 and Feather `main` at `31ab6de` (1 November 2026), which adds 28 commits after the fork |
| **Zag Store compared at** | `main` at `9a3995e4` (13 November 2026) |
| **How** | `git diff`, `git grep` and reading the relevant Swift sources in both trees. Line counts use `wc -l` over `Feather/**/*.swift` |

A Feather feature is called "not built in" only after searching Feather's source for it, at both revisions. Feather is actively developed, so later Feather releases may differ.

## By the numbers

| Measure | Value |
| --- | --- |
| Commits on Zag Store `main` since the fork | **2,071** |
| Swift source in `Feather/` | **10,224 → 50,332** lines (×4.9) |
| New Swift source files | **74** |
| Feather Swift files modified | **46** |
| Lines changed in app, kits, pairing core and tunnel (`git diff --shortstat`) | **+49,534 / −2,586** across 240 files |
| Rust pairing core (`RPPairingCore`) | **2,273** lines |
| Host-run test suites in `scripts/` | **40** |

## Timeline

| | |
| --- | --- |
| **July 2026 · Foundation** | Fork from Feather v2.9.0. Zag Store name, bundle identity and branding |
| **Identity** | Seven original app icons, a cinematic splash with optional sound, retuned accent presets rendered in Display P3, custom colour, wallpapers and Zag Store Designer |
| **Navigation** | Customisable five-slot dock, Discover, Games and Activity, redesigned Sources, Apps, Certificates and Settings, unified search with voice input |
| **Native polish** | Liquid Glass surfaces on iOS 26, native tab and refresh animations, dock that shrinks on scroll, consistent layout and spacing |
| **Installation independence** | On-device RPPairing in Rust, LocalDevVPN integration, health checks and connection traces, Mobile Data Fix with the Zag Mobile Data Toggle Shortcut |
| **Self-updating** | Stable, Beta and Nightly channels, SHA-256 verified downloads, automatic checks, Wi-Fi-only automatic downloads, Ed25519-signed metadata (active on Beta) |
| **Website and Safari install** | zagstore.app catalogue and repository directory, Safari installation with your own certificate, isolated signing service with expiring delivery |
| **Performance and size** | Opt-in on-device performance instrumentation, fewer redundant re-renders, independent startup reconciliation, thumbnail decoding, Release size optimisation |
| **November 2026 · Insights** | Installation attribution and first-launch reporting for website installs, server-side network classification, privacy-bounded aggregation |

## Feature inventory

**Legend:** **Inherited**: from Feather, largely unchanged. **Redesigned**: from Feather, substantially reworked. **New**: added by Zag Store. **Available**: part of the public beta. **In testing**: live, being verified end to end. **Experimental**: diagnostic tools that may change or be removed. **Planned**: not available yet.

### App experience

| Feature | Origin | Status |
| --- | --- | --- |
| AltStore-format repositories | Inherited | Available |
| Sources tab | Redesigned: counts, refresh status, repository provenance for installed apps | Available |
| Library → **Apps** tab | Redesigned: device-reported installed versions, update badges | Available |
| **Discover** tab: spotlight, interest collections, fresh releases | New | Available |
| **Games** tab: genres, Emulators collection | New | Available |
| **Activity** tab: live and past downloads, signing, installs | New | Available |
| **Devices** tab: this device's system and storage | New | Available; managing paired devices is planned |
| Customisable **five-slot dock** (7 destinations) | New (Feather has four fixed tabs) | Available |
| Unified search with **voice input** | New | Available |
| Liquid Glass surfaces (SwiftUI `glassEffect`) | New | Available on iOS 26 |
| Cinematic splash with optional sound | New | Available |
| Original app icons (7) | New (Feather offers alternate *Feather* icons) | Available |
| Accent presets | Inherited, retuned (Native, Violet, Matrix replace three of Feather's) and rendered in Display P3 | Available |
| Custom colour, wallpapers, Zag Store Designer | New | Available |
| Certificate management | Redesigned: status at a glance, voice-searchable list | Available |
| Signing options | Inherited, redesigned presentation | Available |
| Tweak injection (`.deb`, `.dylib` via ElleKit) | Inherited | Available |
| App updates from sources | Inherited (Feather added them in May 2026), extended with startup reconciliation | Available |

### Installation

| Feature | Origin | Status |
| --- | --- | --- |
| On-device signing with Zsign | Inherited | Available |
| Install Zag Store **from Safari** with your own certificate | New (website) | In testing |
| On-device **RPPairing** with a pairing code (iOS 17+) | New | Available |
| Rust pairing core: Pair-Verify, TLS-PSK, RSD, installation proxy, AFC | New | Available |
| Installation health check and connection trace | New | Available |
| Controlled test install, House Arrest browser, update-signature diagnostics | New | Experimental |
| **Mobile Data Fix** (Shortcut-assisted installs on mobile data) | New | Available |
| Pairing-file installation for iOS 16.4–16.7 | Inherited (Feather's *IDevice* method) | Available |
| Feather's *Server* method (local HTTPS + `itms-services`) | Removed in Zag Store | Not included |

### Updates and integrity

| Feature | Origin | Status |
| --- | --- | --- |
| Self-update of Zag Store from inside the app | New | Available |
| Stable, Beta and Nightly channels | New | Available |
| Automatic checks; Wi-Fi-only automatic downloads | New | Available |
| SHA-256 verification of update downloads | New | Available |
| Ed25519-signed metadata with sequence, expiry and rollback protection | New | Active on Beta; Stable and Nightly planned |

### Ecosystem (server-side, not in this repository)

| Feature | Status |
| --- | --- |
| zagstore.app catalogue and repository directory | Beta |
| Isolated signing service with gateway, workers and expiring delivery | In testing, live on zagstore.app |
| Installation attribution and first-launch reporting | In production |
| Network classification of signing requests | In production |
| Installing catalogue apps from the website | Planned |
| Optional accounts and settings sync | Planned |

## Where Feather and Zag Store differ in philosophy

- **Analytics.** Feather describes itself as having no tracking or analytics. Zag Store reports website installations to its own servers: a first-launch report that you can turn off, and opt-in jailbreak status. See [Ecosystem and privacy](ECOSYSTEM.md).
- **Installation methods.** Feather offers a server-based method that needs no pairing. Zag Store dropped it in favour of pairing-based installation, which it extended to work without a computer and on mobile data.
- **Getting the app.** Feather is distributed as an `.ipa` on its Releases page and through its AltSource. Zag Store adds a Safari installer that signs with a certificate you upload to its signing service. Building from source and signing it yourself remains possible.

## Credit

Feather's signing engine, repository models ([AltSourceKit](../AltSourceKit)), SwiftUI helpers ([NimbleKit](../NimbleKit)), tweak support and many of its views remain part of Zag Store. The app's source folder is still called `Feather/`. Zag Store keeps Feather's GPL-3.0 licence and copyright notices. Thank you to Samara and to everyone who contributed to Feather. Their names remain in this repository's history.
