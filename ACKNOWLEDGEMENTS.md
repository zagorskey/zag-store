# Acknowledgements

Zag Store exists because of open-source software. Thank you to everyone below.

## Feather

Zag Store is a fork of **[Feather](https://github.com/claration/Feather)**, created by [Samara (claration)](https://github.com/claration) with many contributors. Feather is licensed under the [GNU General Public License v3.0](LICENSE). Zag Store keeps that licence and Feather's copyright notices. The commit history of everyone who contributed to Feather is preserved in this repository.

Feather in turn acknowledges these projects, several of which Zag Store still uses:

- [idevice](https://github.com/jkcoxson/idevice): communication with the device's services
- [Zsign](https://github.com/zhlynn/zsign): on-device signing, reimplemented for iOS
- [LiveContainer](https://github.com/LiveContainer/LiveContainer): fixes and help, with code carried in Zsign
- [Nuke](https://github.com/kean/Nuke): image caching
- [backloop.dev](https://backloop.dev/), [Vapor](https://github.com/vapor/vapor), [Asspp](https://github.com/Lakr233/Asspp) and [plistserver](https://github.com/nekohaxx/plistserver): Feather's server-based installation, which Zag Store doesn't include

## Components in this repository

| Component | Used for | Licence | Licence text |
| --- | --- | --- | --- |
| [Feather](https://github.com/claration/Feather) | The original app | GPL-3.0 | [LICENSE](LICENSE) |
| [AltSourceKit](AltSourceKit) | Repository models, from Feather | MIT | [AltSourceKit/LICENSE](AltSourceKit/LICENSE) |
| [NimbleKit](NimbleKit) | SwiftUI helpers, from Feather | MIT | [NimbleKit/LICENSE](NimbleKit/LICENSE) |
| [ElleKit](https://github.com/evelyneee/ellekit) | Tweak injection | BSD-style | [LICENSE_ELLEKIT](LICENSE_ELLEKIT) |

## Submodules

| Component | Used for | Licence |
| --- | --- | --- |
| [Zsign](https://github.com/zhlynn/zsign), via `Zsign/` | IPA signing | MIT (`Zsign/LICENSE`) |
| [LiveContainer](https://github.com/LiveContainer/LiveContainer) code in Zsign | Signing fixes | Apache-2.0 (`Zsign/LICENSE_LC`) |
| [idevicekit](https://github.com/claration/idevicekit) and [idevice](https://github.com/jkcoxson/idevice), via `IDeviceKitten/` | Device communication | MIT |

## Swift packages

| Package | Used for | Licence |
| --- | --- | --- |
| [Nuke](https://github.com/kean/Nuke) | Image loading and caching | MIT |
| [OpenSSL](https://github.com/krzyzanowskim/OpenSSL) | Cryptography | Apache-2.0 |
| [Zip](https://github.com/marmelroy/Zip) | Archives | MIT |
| [SWCompression](https://github.com/tsolomko/SWCompression), [BitByteData](https://github.com/tsolomko/BitByteData) | Archives | MIT |
| [APIKit](https://github.com/ishkawa/APIKit) | Networking | MIT |
| [LicensePlist](https://github.com/mono0926/LicensePlist) (build tool, with its own dependencies) | Generating in-app licence notices | MIT |

## Rust crates (RPPairingCore)

| Crate | Used for | Licence |
| --- | --- | --- |
| [idevice](https://github.com/jkcoxson/idevice), via [IDeviceKit-Zag](https://github.com/zagorskey/IDeviceKit-Zag) | Remote pairing, RSD, installation proxy, AFC | MIT |
| [tokio](https://tokio.rs) | Async runtime | MIT |
| [mdns-sd](https://github.com/keepsimple1/mdns-sd) | Service discovery | MIT OR Apache-2.0 |
| [plist](https://github.com/ebarnard/rust-plist) | Property lists | MIT |
| [async_zip](https://github.com/Majored/rs-async-zip) | Archives | MIT |
| [uuid](https://github.com/uuid-rs/uuid), [futures](https://github.com/rust-lang/futures-rs) | Utilities | MIT OR Apache-2.0 |

Licence notices are also generated at build time by LicensePlist, and shown in the iOS Settings app under **Zag Store → Acknowledgements**.

## Artwork and typefaces

The README artwork is original Zag Store artwork. The SVG banners use the viewer's system font. Some PNG showcase images use [Inter](https://github.com/rsms/inter) (SIL Open Font License 1.1).

## Trademarks

Apple, iPhone, iPad, iOS, iPadOS, Safari and Liquid Glass are trademarks of Apple Inc. Zag Store is independent. It isn't affiliated with or endorsed by Apple or the Feather project.
