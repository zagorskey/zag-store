# Zag Store self-update channels

Zag Store 1.0.0 defaults to **Stable**. The existing "Off" prerelease preference is interpreted as Stable. Beta and Nightly are opt-in. The app checks only when the user taps **Check for Updates**; it does not automatically download, sign, or install an update.

## Publishing

Publish a JSON manifest at each path on the `main` branch:

- `releases/stable.json`
- `releases/beta.json`
- `releases/nightly.json`

Each manifest points to an HTTPS IPA download, preferably an asset in this repository's GitHub Releases. **Do not publish a manifest until a genuine, signed IPA exists.** A missing manifest produces a "not published" message rather than offering an imaginary update.

Example (replace ALL placeholders with actual release values):

```json
{
  "version": "1.0.1",
  "build": "2",
  "bundleIdentifier": "com.cwd43.gu29",
  "ipaURL": "https://github.com/zagorskey/zag-store/releases/download/v1.0.1/ZagStore.ipa",
  "sha256": "<64 hexadecimal characters from shasum -a 256>",
  "minimumIOSVersion": "16.0",
  "releaseNotes": "Release notes"
}
```

The application requires HTTPS, a valid 64-character SHA-256, matching bundle ID, compatible iOS, and a newer version/build before offering a candidate. SHA-256 authenticates the download **against the manifest**; it does not independently authenticate the manifest publisher. Publishing permissions and signed release provenance still matter.

## Release safety

The old upstream `.github/workflows/release.yml` is not a production Zag Store signing/publishing pipeline. It references Feather and an unsigned build process; **do not use it to publish a channel manifest or release**. Replace that workflow separately after verifying signing and protecting distribution credentials.

Nightly/Beta builds need monotonically increasing numeric build numbers within a version. Switching to another channel does not force a downgrade. Channel checks do not authorize self-replacement; signed candidate validation and explicit installation confirmation remain separate.
