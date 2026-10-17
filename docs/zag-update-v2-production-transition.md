# Zag Store authenticated metadata v2 — production transition gates

Status: **staged / not enabled**. This document does not install keys, publish metadata, or change the live Stable/Beta/Nightly updater.

## Verified staging evidence

- Python JCS Ed25519 disposable key -> Swift CryptoKit signature verification passed, including Unicode release notes.
- Negative interoperability tests passed: tampered payload, unknown key, forged signature, extra/duplicate envelope fields, channel mismatch, and unchanged Keychain rollback history.
- Foundation JSON serializer does **not** implement general RFC 8785: differences observed for selected floating-point values. Current payload schema is constrained to integer and string fields.

## Decisions required before cutover

1. **Trust anchor**: provision an offline-generated Ed25519 keypair; commit only public raw key bytes and a stable key ID in the app. Do not store private keys in GitHub, app bundles, or CI logs. Document secure backup/recovery and key revocation procedures.
2. **Publisher**: publish canonical signed envelopes per channel and an immutable IPA artifact with matching SHA-256; perform independent verification of the artifact, bundle identifier (`app.zagstore.ios`), version/build, URL, and manifest expiry.
3. **Rotation**: ship a new app version trusting the next public key *before* signing with it. Keep previous key during overlap; test compromised-key emergency recovery separately.
4. **No downgrade**: after a channel has accepted authenticated v2 metadata, never silently fall back to unsigned v1 for that channel. A missing/invalid v2 manifest is an error, not permission to fetch v1.
5. **Migration**: maintain the existing v1 URLs untouched during preparation. Roll out v2 behind an explicit per-channel migration gate only after keys and signed manifests are published and validated. Test all three channels independently.
6. **Rollback semantics**: test first-run pinning, increasing sequence, same-sequence equality, downgrade, corrupt Keychain item, and app reinstall/keychain persistence. An accepted metadata sequence does not by itself guarantee an installed IPA.
7. **Operational reliability**: manifest expiry is limited to seven days. Plan timely re-signing of channel metadata, outage behavior, clock skew handling, and recovery without weakening signature checks.
8. **Parity**: confirm the existing per-device signing/install flow, current bundle identity, app data, pending-install reconciliation, update badge, and explicit user initiation still behave as before.

## Current code observations

- `ZagSelfUpdateCoordinator.fetchUpdate` currently downloads and decodes unsigned v1 JSON with `Release`. Its three channel URLs are under `zag-store-releases/main/releases/<channel>.json`.
- `ZagUpdateVerifiedPipeline.accept` is staged and independent of live discovery. It authenticates the envelope, validates payload, then records channel rollback state.
- `ZagUpdateRollbackStore` writes a channel-specific sequence and payload SHA-256 to Keychain. It is actor-isolated within one process, not cross-process compare-and-swap.
- `ZagUpdateMetadataV2` has no installed production trust anchor; only disposable test keys have been exercised.

## Cutover sequence

1. Add app-side public-key trust store and test-only injection, without changing current discovery.
2. Add read-only v2 discovery in a nonproduction path, with strict URL and response checks.
3. Prepare offline production signing and independent verification, then publish test-channel envelopes.
4. Exercise staged v2 end-to-end on a test device through per-user IPA signing.
5. Enable one channel under a one-way authenticated migration marker, then evaluate before widening rollout.

**Never flip live v1 discovery to v2 or add a v1 fallback after authenticated migration simply because a test passes.**

## Production key ceremony and rotation checklist (staged)

The application trust store remains **empty** until an independently verified public key is reviewed. Keep private signing material entirely outside the app, source control, build artifacts and GitHub Actions.

### Offline generation and custody

1. On a trusted, offline machine, generate the production Ed25519 signing key with audited tooling. Use a non-exportable hardware-backed key if the chosen signing workflow supports Ed25519; otherwise use encrypted storage with restricted access.
2. Produce the **32-byte raw Ed25519 public key** and publish its SHA-256 fingerprint through a separate, independently verified channel. Record generation date, custodian, allowed channels, backup location, and a non-secret key ID (64 UTF-8 bytes maximum).
3. Have two maintainers independently check the public key bytes, fingerprint and key ID before proposing an app trust-store change. Never copy the private key into a repository, CI environment, IPA or chat.
4. Store recovery material separately; rehearse restoring it without uploading private material. Log authorisation and sign-offs outside the release artifacts.

### Rotation without silent downgrade

1. Pre-provision the successor public key in a released app version before publishing any manifest signed by it. Maintain a defined overlap period for the old and new keys.
2. Sign a fresh, strictly canonical v2 envelope with the successor key; validate its key ID, channel, expiry, monotonic sequence, payload SHA and associated immutable IPA before publishing.
3. After confirmed rollout, retire the previous key in a subsequent app update. An app that still trusts an old key cannot be protected against a compromise merely by publishing a new manifest; document recovery and forced-upgrade limitations.
4. Keep signed v2 acceptance one-way per channel. Missing, expired or invalid v2 metadata must fail closed, never select an unsigned v1 manifest as fallback.
5. Test recovery, rollback and key overlap on all Stable/Beta/Nightly channels independently, including stale clients, missing manifests and compromised-key assumptions.

### Verification gates before any production activation

- Independently verify the exact release bytes, raw public-key fingerprint, canonical envelope, expiry horizon (seven days maximum), channel and sequence. Use two separate implementations where practical.
- Validate that the manifest points to an immutable canonical IPA with the expected publisher ID `app.zagstore.ios`; confirm the device-specific resigning preserves the user's actual installed bundle identifier.
- Test a real device with a disposable *nonproduction* signing key and v2 test endpoint, retaining the live v1 endpoints unchanged.
- Obtain explicit approval for shipping reviewed public keys and, separately, for enabling the irreversible per-channel migration gate. No stage is enabled simply because these checks are documented.
