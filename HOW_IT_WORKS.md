# How Zag Store works

A technical overview of how Zag Store signs and installs apps, and how it updates itself. For setup steps, see the [installation guide](docs/INSTALL.md).

## Signing

Every app needs a valid signature before iOS will install it. Zag Store signs IPAs **on the device** with [Zsign](https://github.com/zhlynn/zsign), using the `.p12` certificate and `.mobileprovision` profile you imported. Signing options can change the app's name, bundle identifier, version and appearance, enable file sharing, add Liquid Glass compatibility and inject tweaks (`.deb`, `.dylib`) through ElleKit. Most of this is inherited from Feather.

Zag Store itself can also be signed on [zagstore.app](https://zagstore.app/install/). That signing runs on Zag Store's signing service, not on the device. See [Ecosystem](docs/ECOSYSTEM.md#the-signing-service).

## Installing on iOS 17 and later: RPPairing

iOS 17 replaced the old lockdown pairing with **RemotePairing**, the protocol Apple's own tools use to talk to a device over an encrypted tunnel. Zag Store talks RemotePairing to the device it's running on, so it needs no computer.

1. **A local network path.** [LocalDevVPN](https://apps.apple.com/app/localdevvpn/id6755608044) creates an on-device VPN that loops traffic back to the device's own services at `10.7.0.1`. Zag Store watches the tunnel and shows its state.
2. **Pairing, once.** Zag Store advertises itself as a pairable host and iOS connects to it. Zag Store shows the pairing code and keeps the resulting pairing credentials on the device.
3. **Every install.** The Rust core (`RPPairingCore`, built on [idevice](https://github.com/jkcoxson/idevice)) runs **Pair-Verify** with the saved credentials, opens a **TLS-PSK** tunnel, and uses **RSD** to discover services. It uploads the signed IPA to `PublicStaging` with **AFC**, then asks the **installation proxy** to install it, reporting progress as it goes.
4. **Verification.** The installation proxy also reports the installed apps, with versions and builds. Zag Store uses that list for the Apps tab and update checks.

**Settings → Installation → Diagnostics** runs each of these stages as a health check. It also offers a connection trace, an installed-app inventory and a controlled test install.

## Mobile data

With Mobile Data switched on, iOS refuses connections through LocalDevVPN to the installer port. Zag Store recognises this from the installer's own answer (connection refused), not from interface lists, which the VPN makes unreliable. Then:

1. If Wi-Fi is available, or the port answers, the install runs directly.
2. Otherwise, with your approval and a verified **Zag Mobile Data Toggle** Shortcut, Zag Store sends `off`, installs, then sends `on`. Each command is sent at most once per job, and `on` is sent only after the installer has returned.
3. A recovery record is saved before `off` and kept until Mobile Data is seen on again, so an interrupted install can't leave Mobile Data off.

The Shortcut's generator and inspector are in [`tools/zag-mobile-data-toggle`](tools/zag-mobile-data-toggle/README.md).

## Installing on iOS 16.4 to 16.7

Older versions use the method inherited from Feather: a lockdown **pairing file** created on a computer, a heartbeat over LocalDevVPN, AFC upload to `PublicStaging`, and the installation proxy.

Feather's other method, a local HTTPS server with `itms-services`, is not included in Zag Store.

## Self-update

1. Zag Store fetches the selected channel's manifest from [zag-store-releases](https://github.com/zagorskey/zag-store-releases).
2. On **Beta**, the manifest is **authenticated metadata v2**: canonical JSON signed with Ed25519, carrying a sequence number and an expiry time. It's verified against public keys built into the app, and a rollback store refuses older sequences. See the [protocol](releases/AUTHENTICATED-METADATA-V2.md).
3. An update is offered only if its version and build are newer than the installed copy.
4. The IPA is downloaded, automatically on Wi-Fi if you allow it, and checked against the manifest's SHA-256.
5. After you approve, Zag Store signs it with your certificate and installs it directly, without the Mobile Data Fix wrapper. It then confirms the new build on the next launch.
