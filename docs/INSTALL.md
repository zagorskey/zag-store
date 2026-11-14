# Installing Zag Store

Zag Store installs from Safari on the iPhone or iPad you want to use it on. You don't need a computer, a cable or a second device. This guide covers what you need, what happens at each step, and what to do when something goes wrong.

> [!NOTE]
> Zag Store is in **public beta**, and the Safari installer is **in testing**. Features and steps may change as the beta develops.

## Requirements

| | Needed for |
| --- | --- |
| An iPhone or iPad with **iOS or iPadOS 16.4 or later** | Running Zag Store |
| Your own **signing certificate (`.p12`)** and its password | Signing Zag Store, and every app you install with it |
| A **provisioning profile (`.mobileprovision`)** that includes your device | Letting iOS install apps signed with your certificate |
| **Safari** on that device | Installing Zag Store from zagstore.app |
| **Developer Mode** turned on | Installing apps directly from Zag Store |
| **[LocalDevVPN](https://apps.apple.com/app/localdevvpn/id6755608044)** from the App Store | The on-device connection Zag Store uses to install apps |
| **iOS 17 or later** | On-device pairing with no computer. On iOS 16.4–16.7, see [Older iOS versions](#older-ios-versions) |

Zag Store doesn't provide, share or rent certificates, and never asks for your Apple Account password. Get your certificate and profile from your own Apple developer account or another source you trust.

## What each step needs

The stages have different requirements. Here they are, separated:

| Stage | What happens | Needs | Doesn't need |
| --- | --- | --- | --- |
| **1. Install Zag Store** | Safari sends your certificate, password and profile to Zag Store's signing service, which signs one copy and returns a private link that expires | Internet, Safari, certificate, profile that includes the device | A computer, cable, second device or desktop utility |
| **2. Pair** (once) | Zag Store pairs with the device it's running on | iOS 17+, Developer Mode, LocalDevVPN connected | A computer or pairing file (iOS 17+) |
| **3. Sign apps** | Zag Store signs each app on the device with your certificate | An imported certificate and profile | A network connection to any signing server |
| **4. Install apps** | Zag Store installs through LocalDevVPN and the iOS installation services | The saved pairing, LocalDevVPN, Wi-Fi **or** mobile data (with the Shortcut) | Wi-Fi specifically |
| **5. Update Zag Store** | Zag Store downloads an update, checks its SHA-256, signs it with your certificate and installs it | Your approval; Wi-Fi for automatic downloads | Reinstalling from the website |

In every stage, iOS still checks the signature and the provisioning profile. Apple's platform rules apply as usual.

## 1. Install Zag Store from Safari

1. On the iPhone or iPad, open **[zagstore.app/install](https://zagstore.app/install/)** in Safari.
2. Choose your **signing certificate (`.p12`)** and **provisioning profile (`.mobileprovision`)**, and enter the certificate password.
3. Tap **Sign Zag Store**. Signing takes a short while. You'll see its progress.
4. Tap **Install Zag Store** and confirm when iOS asks.
5. The first time you open an app signed with a development certificate, iOS may ask you to trust the developer. Do this in **Settings → General → VPN & Device Management**.

**About your certificate.** The installer page doesn't save your certificate, profile or password. They go over an encrypted connection to Zag Store's isolated signing service, only to sign this copy of the app. If you'd rather not upload a certificate to any service, [build Zag Store from source](BUILDING.md) and sign it with your own tools.

**Using a VPN or iCloud Private Relay?** You don't need to turn it off. If signing doesn't start or stops responding, pausing it briefly and trying again can help.

## 2. Set up direct installation

1. Turn on **Developer Mode** in **Settings → Privacy & Security → Developer Mode**, and restart when iOS asks.
2. Install **[LocalDevVPN](https://apps.apple.com/app/localdevvpn/id6755608044)** and connect it.
3. In Zag Store, import your certificate in **Settings → Certificates**.
4. Open **Settings → Installation** and tap **Pair This iPhone**. iOS connects to Zag Store, usually while you're in the Developer Mode settings. Zag Store then shows a **pairing code**, also as a notification if you allow notifications. Enter it when iOS asks.

Zag Store saves the pairing credentials on the device and reuses them for every install. To remove them, tap **Unpair This iPhone**.

## 3. Install apps

Add repositories in **Sources**, find an app in **Discover**, **Games** or **Sources**, and tap **Get**. Zag Store downloads, signs and installs it. **Activity** shows each step.

### On mobile data

iOS refuses Zag Store's local installation connection while Mobile Data is switched on. Zag Store recognises this from the installer's response and offers **Mobile Data Fix**:

1. In **Settings → Installation**, choose **Apply Mobile Data Fix** and add the official **Zag Mobile Data Toggle** Shortcut. Zag Store checks that the Shortcut is ready before using it.
2. When an install needs it, and only with your approval, Zag Store runs the Shortcut to switch Mobile Data **off** for the install and back **on** straight afterwards.

The Shortcut accepts exactly three commands (`status`, `off`, `on`) and never toggles blindly. It sets Mobile Data to an explicit state. On Wi-Fi, none of this happens.

## Alternative: sign the unsigned IPA yourself

If you'd rather not use the Safari installer, sign Zag Store with your own tools:

1. Download `ZagStore-1.0.0-unsigned.ipa` from the **[1.0.0 Beta 2 release](https://github.com/zagstore/zag-store/releases/tag/v1.0.0-beta.2)**.
2. Check that its SHA-256 checksum is exactly:

   ```
   5bb93c02230a97f3b4eb2c22e4f98ba15f4c5cf71602c2035de139ed81193cd6
   ```

   On a Mac, run `shasum -a 256 ZagStore-1.0.0-unsigned.ipa`. If the checksum differs, don't install the file.
3. Sign it with your certificate and a provisioning profile that includes your device, using any signing tool you trust, then install it.

Then continue with [Set up direct installation](#2-set-up-direct-installation).

## Updating Zag Store

Zag Store checks for updates on launch and when you return to it. Choose the **Stable** (default), **Beta** or **Nightly** channel in Settings. Downloads are SHA-256 verified. **Download Updates on Wi-Fi** downloads automatically on Wi-Fi only. Signing and installing always wait for your approval. See [release channels](../releases/README.md).

**Coming from Beta 1?** Beta 2 signs its update information with a new key, `zag-v2-2026-b`. Beta 1 trusts only the retired key, so it can't verify this update and reports that the update information is signed with a key it doesn't trust. Install Beta 2 once, manually, from the Safari installer or the unsigned IPA. From Beta 2 on, Beta updates arrive in the app.

## Older iOS versions

On **iOS 16.4 to 16.7**, Zag Store uses the earlier installation method inherited from Feather. It needs a **pairing file** created on a computer (for example with [Impactor](https://github.com/khcrysalis/Impactor)) and imported in **Settings → Installation**, plus LocalDevVPN.

## Troubleshooting

| Problem | Try |
| --- | --- |
| Signing on the website doesn't start | Check that the certificate password is right and that the profile matches the certificate. Pause a VPN or Private Relay briefly and retry |
| iOS says the app can't be installed | The provisioning profile probably doesn't include this device, or the certificate has expired or been revoked |
| "Untrusted Developer" | Trust the certificate in **Settings → General → VPN & Device Management** |
| Direct install fails | Connect LocalDevVPN, check that Developer Mode is on, then run the **health check** in **Settings → Installation → Diagnostics** |
| Install fails on mobile data | Set up Mobile Data Fix, or connect to Wi-Fi |
| Still stuck | Ask at [zagstore.app/support](https://zagstore.app/support/) or [open an issue](https://github.com/zagstore/zag-store/issues/new/choose). Remove personal and signing information from any logs |

Diagnostic reports from Zag Store include the network type, timings and the first failing step. They don't include pairing records, certificate material or private keys. Still, check a report before you share it.
