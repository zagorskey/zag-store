# Zag Store features

A tour of the app as it is in the current public beta. To see which features came from Feather and which are new, read the [feature inventory](FROM-FEATHER.md#feature-inventory).

## Navigation

- **A dock you arrange.** Choose up to five of seven destinations: Discover, Sources, Apps, Games, Activity, Devices and Settings. Put them in any order and pick the start page. Zag Store can also remember the last page. The dock can shrink as you scroll. *Settings → Bottom Dock*.
- **Account menu.** Certificates, devices and settings are also reachable from the account button.
- **Deep links.** `zagstore://discover`, `zagstore://sources`, `zagstore://apps`, `zagstore://games`, `zagstore://activity`, `zagstore://devices` and `zagstore://settings` open those destinations directly.

## Discover

- **In the Spotlight.** Featured apps from your sources, with promotional artwork.
- **Explore by Interest.** Collections built from app names and descriptions, with counts and one-tap filters.
- **Fresh Releases.** Recently updated apps across all your repositories.
- **Surprise Me** and **Saved Apps.** Find something new, or come back to an app later.

## Sources

- Add any **AltStore-format** repository and see its app count and when it last refreshed.
- Repositories refresh in the background, and a refresh that doesn't finish never discards known-good update information.
- Zag Store remembers which repository each installed app came from, even when several offer the same bundle identifier.

## Apps

- Your signed and installed apps, with installed versions and builds read from the device.
- **Update badges** and an *Updates Available* section, styled with the Designer.
- Install, update, share and remove apps, with progress shown in Activity.

## Games

- Genre shelves and a separate **Emulators** collection.
- Native scope controls switch between games and emulators.
- Featured cards with screenshot galleries.

## Activity

Every download, signing step and installation, live and in history.

## App pages

- Promotional artwork, a horizontally scrolling screenshot gallery and a full-screen viewer.
- Version, source and bundle identifier.
- Artwork has fallbacks when a repository's images are missing.

## Search

The same native search field in Discover, Sources, Apps, Games and Certificates, with **voice search** wherever iOS offers dictation. The microphone is used only when you tap it.

## Certificates and signing

- Import `.p12` certificates and provisioning profiles. Expiry and status are shown at a glance.
- Choose which certificate signs each app.
- **Signing options:** app name, bundle identifier and version, appearance, file-sharing support, Liquid Glass compatibility, plus tweak injection of `.deb` and `.dylib` files through ElleKit, and more.

## Installation

- **RPPairing:** pair the device with itself using a pairing code (iOS 17+).
- **LocalDevVPN status** shown in the app.
- **Mobile Data Fix** for installs on mobile data.
- **Diagnostics:** a full health check (pairing, Pair-Verify, TLS-PSK, RSD, installation proxy, app lookup, AFC), a connection trace, an installed-app inventory, and a controlled test install.
- **Pairing-file method** for iOS 16.4–16.7.

See the [installation guide](INSTALL.md).

## Updates

- **Channels:** Stable (default), Beta and Nightly.
- **Automatic Updates:** check on launch and on return, and optionally download on Wi-Fi.
- Downloads are SHA-256 verified. Beta metadata is also **Ed25519-signed**.
- Signing and installation always wait for your approval.

See [release channels](../releases/README.md).

## Appearance

- **Mode:** Light, Dark or Automatic.
- **Theme:** accent presets including Native, Violet and Matrix, or a **custom colour**.
- **Wallpapers.**
- **App icons:** Official, Liquid Glass, Burning Wood, Matrix, Golden Reserve, Sterling and Neon Flux.
- **Zag Store Designer:** live-preview control of header alignment, rows, separators and badges.
- **Splash:** the cinematic launch, with an optional sound that respects the silent switch.

## Privacy and diagnostics

- **Performance diagnostics:** opt-in and on-device. See [Performance diagnostics](PERFORMANCE-DIAGNOSTICS.md).
- **Diagnostic reports** exclude pairing records, certificate material and private keys.
- **First-launch report and jailbreak status:** for copies installed from the website. See [Ecosystem and privacy](ECOSYSTEM.md#privacy).
- **Settings backup** of Zag Store preferences.
