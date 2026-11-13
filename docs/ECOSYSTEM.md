# The Zag Store ecosystem

Zag Store is an iOS app **and** a set of services around it. This repository contains the app. The services below run on Zag Store's own infrastructure. Their source isn't published here, and this page deliberately leaves out endpoints, hosts and other operational detail.

| Component | What it does | Where |
| --- | --- | --- |
| **Zag Store for iOS** | Discover, sign, install and update apps on the device | This repository |
| **[zagstore.app](https://zagstore.app)** | App catalogue, repository directory, guides and the Safari installer | Website |
| **Signing service** | Signs Zag Store with your certificate for Safari installation | Private service |
| **Release channels** | Publishes Stable, Beta and Nightly update metadata | [zag-store-releases](https://github.com/zagorskey/zag-store-releases) (public) |
| **Installation insights** | Attribution, first-launch and network reports, shown in totals | Private service |

## zagstore.app

- **Catalogue.** Curated apps first, then apps from every repository Zag Store reads. Search by name or bundle identifier, and filter by category. When several repositories offer the same app, the catalogue recognises it by its identifier and lists it once, naming every source.
- **Repositories.** Each source's app count, last sync time and link.
- **Install.** The Safari installer described below.
- **[How it works](https://zagstore.app/how-it-works/)** shows what is in beta, in testing and planned.

## The signing service

When you install Zag Store from Safari:

1. The installer page sends your certificate, password and profile, with the request, over an encrypted connection.
2. A **gateway** validates the request and its credential frames strictly, then hands the job to a **separate, sandboxed signing worker**.
3. The worker signs one copy of Zag Store. The result is bound to the **job's identity**, the expected **bundle identifier** and the **SHA-256** of the signed artifact.
4. You receive a **private install link, scoped to the job, that expires**. iOS downloads and installs the app after verifying it.

Design principles:

- **Bring your own certificate.** Zag Store never provides certificates. The page doesn't save yours, and it's used only to sign that copy.
- **Fail closed.** A request that is malformed, tampered with, mismatched, expired or in an unsupported protocol version is rejected. It never falls back to a weaker path.
- **Separate environments.** Preview and production use separate signing lanes, data and configuration.
- **Tested.** Regression suites cover malformed input, wrong identities, tampered artifacts, expired credentials and incompatible protocols.

If you don't want to upload a certificate to any service, [build Zag Store](BUILDING.md) and sign it yourself.

## Release channels

Zag Store updates itself from manifests published in the public [zag-store-releases](https://github.com/zagorskey/zag-store-releases) repository.

- **Stable** (default), **Beta** and **Nightly**.
- Every download is checked against the SHA-256 in its manifest.
- **Beta** uses **authenticated metadata v2**. Each manifest is signed with Ed25519 and carries a sequence number and an expiry time. The app checks it against public keys built into the app, never keys fetched from the manifest. It rejects replayed, expired, rolled-back, non-canonical or tampered metadata, and it compares version and build before offering an update. Stable and Nightly will move to v2 later.
- See [release channels](../releases/README.md), the [v2 protocol](../releases/AUTHENTICATED-METADATA-V2.md) and its [security review](../releases/AUTHENTICATED-METADATA-V2-SECURITY-REVIEW.md).

## Privacy

Some features run on your device and some on Zag Store's servers. This section separates them.

### On your device

- **Certificates, profiles and pairing credentials** used by the app stay in the app. Signing inside the app happens on the device.
- **Performance diagnostics** are opt-in and never sent. See [Performance diagnostics](PERFORMANCE-DIAGNOSTICS.md).
- **Diagnostic reports** are created only when you copy them. They exclude pairing records, certificate material and private keys.

### When you sign on zagstore.app (server-side)

- Your certificate, password and profile are used to sign one copy, then discarded. The page doesn't save them.
- The service records signing and download events and attributes each installation to the website it came from.
- The IP address of a signing request is classified by a third-party IP-reputation service, for example to recognise a VPN and its provider. This is server-side network classification, not on-device inspection.
- Installation statistics count each installation once, even when it was both signed and downloaded.

### When a website-installed copy first opens

| Report | Default | Contents |
| --- | --- | --- |
| **First-launch report** | **On.** Turn it off in Settings and nothing is sent | Sent once over an encrypted connection: the download's installation code, a random report ID, the app version and build, the iOS version and build, and the device model |
| **Jailbreak status** | **Off.** Opt in | Sent once: yes, no or unknown, and rootless or rootful. Never which files, tweaks or apps were found |

- The server stores these reports **without your IP address**.
- The installation code identifies the website download, not you. Anyone with a copy of the same download could send the same code, so a report is not proof of a unique device.
- Jailbreak statistics are published only as **weekly totals of at least 10 devices**. Individual results are deleted within **30 days**.
- Zag Store does not collect installed-app lists or hardware identifiers.
