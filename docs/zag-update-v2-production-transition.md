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
