# Source provenance

This page records which source each published Zag Store build was made from. Each release's complete corresponding source is public, including every submodule.

## 1.0.0 Beta 2 (build 2)

| | |
| --- | --- |
| Release | [`v1.0.0-beta.2`](https://github.com/zagstore/zag-store/releases/tag/v1.0.0-beta.2) |
| Unsigned IPA | [`ZagStore-1.0.0-unsigned.ipa`](https://github.com/zagorskey/zag-store-releases/releases/download/v1.0.0-beta.2/ZagStore-1.0.0-unsigned.ipa) |
| IPA SHA-256 | `5bb93c02230a97f3b4eb2c22e4f98ba15f4c5cf71602c2035de139ed81193cd6` |
| App source | `a2a2475a1d63706423fa2f5442e4de2cfe1811ec`, merged into `main` by `afb85da912f81aca128239063debb87668c6be90` |
| `Zsign` | [zagorskey/Zsign-Zag](https://github.com/zagorskey/Zsign-Zag) `ab5791658466abc5ebf43fa329dec308acecb922` (tag `zag-1.0.0-beta.2`) |
| `IDeviceKitten` | [zagorskey/IDeviceKit-Zag](https://github.com/zagorskey/IDeviceKit-Zag) `47476ac2a220d30fe89c8b12992197d0aaf7d61d` |
| Rust `idevice` crate | [zagorskey/IDeviceKit-Zag](https://github.com/zagorskey/IDeviceKit-Zag) `191f36cae9b08b21b6610452fb1771880b4eae45` |

### Why the commit hashes differ from the build

The IPA was built from commit `293def6f` in Zag Store's earlier private repository. When the project moved to this public repository, that repository's history was rewritten once to remove personal data: a real device identifier used as a test value, and a personal email address in commit metadata. Rewriting history changes commit hashes, so:

- `293def6f` (private) corresponds to `a2a2475a` (here). Their trees differ in one test file only: `scripts/ZagDeviceLinkTests.swift` uses the synthetic identifier `00008130-0001A2B3C4D5E6F7` in place of the real one. That file isn't compiled into the app.
- Zag Store's private Zsign fork at `fc414a4` corresponds to `ab579165` in Zsign-Zag. Both have the same source tree, `d2d1add935828466d69ae10c59a0a8433218cb7c`. Zsign-Zag holds upstream Zsign-Package history up to `6ffe703` and one commit with Zag Store's changes.
- Upstream Feather history, before Zag Store, kept its original hashes.

Later commits on `main` change only documentation and the Zsign submodule's repository and pin, whose source tree is identical. The app source is unchanged.

## Licences

Zag Store is licensed under the GNU General Public License v3.0 ([LICENSE](../LICENSE)). Zsign-Zag keeps its upstream licence files unchanged: Zsign's MIT licence (`LICENSE`) and the Apache License 2.0 that covers the LiveContainer code it carries (`LICENSE_LC`). Components and their licences are listed in [ACKNOWLEDGEMENTS.md](../ACKNOWLEDGEMENTS.md).
