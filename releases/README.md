# Zag Store self-update channels

Zag Store 1.0.0 defaults to **Stable**. The existing "Off" prerelease preference is interpreted as Stable. Beta and Nightly are opt-in. The app checks the selected channel at launch and when returning to the foreground (throttled to six hours). Manual checks remain available. Downloads require user action; signing and installation are not automatic.

## Publishing

Use the local signed-IPA publisher after compiling and signing with `ZagStore-Package.zsh`:

```zsh
zsh scripts/publish-zag-release.zsh beta "$HOME/Documents/ZagStore-v1.0.0-build3-iOS-AppTesters.ipa" --publish 2>&1 | tee /tmp/zag-publish-beta.log
```

Before publishing the first Nightly, validate its **actual signed IPA** without changing the public repository:

```zsh
zsh scripts/publish-zag-release.zsh nightly "$HOME/Documents/ZagStore-v1.0.0-build3-iOS-AppTesters.ipa" --dry-run 2>&1 | tee /tmp/zag-nightly-preflight.log
```

This is an example filename only: use the real signed IPA path and ensure its build exceeds every published channel. A successful dry run checks the IPA, its signing structure, bundle identity, release tag availability, and cross-channel version ordering; it does **not** upload a release or create a manifest. It is not a device-installation test. After a separate on-device validation and explicit release approval, use `--publish` to publish. Omitting the third argument defaults to a dry run.

The command is an **example**, not an instruction to publish build 3 until it has been tested. The publisher checks the IPA signature and bundle identity, refuses a duplicate release tag or non-increasing channel version/build, uploads the release asset, downloads it back to verify SHA-256, then updates the public channel manifest last. It reads the minimum supported iOS version from the signed app payload. It does not compile, sign, or install the app. Stable and Nightly remain unpublished until separately authorized.

**Important:** The signed IPA contains a device-specific provisioning profile. Public distribution exposes the embedded signing metadata. Never commit private certificates, provisioning secrets, or signing keys.



Publish a JSON manifest at each path on the `main` branch of the public [`zag-store-releases`](https://github.com/zagorskey/zag-store-releases) repository:

- `releases/stable.json`
- `releases/beta.json`
- `releases/nightly.json`

Each manifest points to an HTTPS IPA download, preferably an asset in the public distribution repository's GitHub Releases. **Do not publish a manifest until a genuine, signed IPA exists.** A missing manifest produces a "not published" message rather than offering an imaginary update.

Example (replace ALL placeholders with actual release values):

```json
{
  "version": "1.0.1",
  "build": "2",
  "bundleIdentifier": "com.cwd43.gu29",
  "ipaURL": "https://github.com/zagorskey/zag-store-releases/releases/download/v1.0.1/ZagStore.ipa",
  "sha256": "<64 hexadecimal characters from shasum -a 256>",
  "minimumIOSVersion": "16.0",
  "releaseNotes": "Release notes"
}
```

The application requires HTTPS, a valid 64-character SHA-256, matching bundle ID, compatible iOS, and a newer version/build before offering a candidate. SHA-256 authenticates the download **against the manifest**; it does not independently authenticate the manifest publisher. Publishing permissions and signed release provenance still matter.

## Cross-channel version and build policy

Every newly published Stable, Beta, or Nightly release must have a **strictly newer**
`(version, build)` pair than the latest published release in **each** channel.
Versions use numeric dot-separated components (for example, `1.0.1`); builds
are numeric. Compare versions first, then builds within an equal version.

- Use one globally increasing build sequence for the same app version.
- Never reuse a published version/build for a different channel.
- A Stable promotion therefore needs its own newer signed IPA/build, rather
  than repointing Stable to an existing Beta IPA.
- Switching channels is opt-in and never forces an installed downgrade.
- Missing Stable or Nightly manifests remain unpublished until a real signed
  release is ready. Do not publish placeholders.

The publisher enforces this against all manifests present in the public
distribution repository. The app independently offers only updates newer
than its installed version/build. This policy does **not** guarantee that
a channel switch immediately has an available update: a selected channel
can legitimately lag behind the installed build.

## Release safety

The old upstream `.github/workflows/release.yml` is not a production Zag Store signing/publishing pipeline. It references Feather and an unsigned build process; **do not use it to publish a channel manifest or release**. Replace that workflow separately after verifying signing and protecting distribution credentials.

Nightly/Beta builds need monotonically increasing numeric build numbers within a version. Switching to another channel does not force a downgrade. Channel checks do not authorize self-replacement; signed candidate validation and explicit installation confirmation remain separate.
