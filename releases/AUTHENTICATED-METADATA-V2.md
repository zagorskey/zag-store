# Zag Store authenticated update metadata — protocol v2

Status: **design baseline, not yet enforced by the iOS client**. Do not publish v2 metadata or switch production URLs until the verifier, publisher and migration tests pass.

## Trust boundary

GitHub Releases and Cloudflare are untrusted distribution transports. The iOS client must verify release metadata against public keys embedded in the app **before** using an IPA URL, version, notes, minimum iOS, or SHA-256. SHA-256 alone is insufficient when the manifest can be replaced.

## Envelope and exact signed bytes

A v2 channel response is UTF-8 JSON:

```json
{
  "schema": 2,
  "keyId": "zag-release-2026-01",
  "payload": "BASE64_OF_UTF8_CANONICAL_JSON",
  "signature": "BASE64_OF_64_BYTE_ED25519_SIGNATURE"
}
```

The Ed25519 signature is computed over the raw decoded `payload` bytes, prefixed with the domain-separation string `ZAG-STORE-UPDATE-V2\n` (ASCII). Never reserialize parsed JSON to verify a signature. `payload` must be canonical JSON (RFC 8785 / JCS); reject duplicate JSON keys, unknown schema versions, noncanonical payloads, invalid base64, or signatures of the wrong length. Publisher and client must share golden test vectors.

The signed payload includes all fields below (illustrative only):

```json
{
  "schema": 2,
  "appId": "com.cwd43.gu29",
  "channel": "beta",
  "sequence": 3,
  "version": "1.0.0",
  "build": "3",
  "minimumIOSVersion": "16.0",
  "ipaURL": "https://github.com/zagorskey/zag-store-releases/releases/download/EXAMPLE/ZagStore.ipa",
  "sha256": "64_lowercase_hex_characters",
  "releaseNotes": "Example only",
  "publishedAt": "2026-10-17T00:00:00Z",
  "expiresAt": "2026-10-24T00:00:00Z"
}
```

All signed fields are validated: fixed bundle ID; channel matches requested endpoint; HTTPS IPA URL on an explicit allowlist; strictly numeric version/build; lowercase 64-hex SHA; valid ISO-8601 UTC timestamps; expiration after publication; reasonable maximum lifetime; and positive integer sequence. The verifier rejects expired metadata for **new installation authorization**. Cached verified metadata may be displayed as stale, but must not authorize an installation after expiry.

## Rollback and replay resistance

Store the highest verified `sequence` per channel and the highest installed `(version, build)` in persistent local state. Reject lower sequences and conflicting payloads for an equal sequence; allow identical responses. A newly published channel manifest increments its channel sequence even when no app build is released (e.g. a security revocation). The publisher also enforces globally increasing version/build for new IPA releases. A reinstall or erased local state cannot rely on a device-local counter alone; the signing/publishing authority must never reissue old sequences as current.

Cross-channel switching never authorizes a downgrade. A revocation mechanism will be designed before enabling rollback or emergency override.

## Key management

Private Ed25519 signing keys **never** enter the source repository, GitHub Releases, Cloudflare Worker, or IPA. The client embeds a small trust set of public keys indexed by `keyId`. Publish key rotation by shipping an app version that trusts both old and new keys, verify its adoption, then begin signing with the new key. Remove retired keys only after a planned transition. Key compromise requires a separate incident response and an app update; simply changing a CDN response cannot repair a compromised embedded trust root.

Release signing and IPA code signing are separate operations. A valid manifest signature does not replace IPA hash checks, iOS code-signature verification, team/entitlement checks, or explicit user approval.

## Deployment and compatibility

1. Implement a deterministic publisher-side signer and offline golden vectors without a production private key.
2. Implement a fail-closed Swift/CryptoKit verifier and tests for signature tampering, wrong channel/app, expiry, sequence rollback, and malformed inputs.
3. Release a client that understands both legacy v1 and v2 **only during a bounded migration**. Never silently fall back to v1 after a v2 verification failure.
4. Publish v2 metadata at new, separate endpoints and validate through Beta first.
5. Migrate Stable/Nightly when genuine signed releases are available; only then retire legacy manifests.

Cloudflare Workers/CDN may cache and deliver the **unchanged signed envelope**. Cache TTL must not extend authorization past `expiresAt`; stale-if-error is display-only. Use immutable, content-addressed IPA URLs where practical, conditional GET/ETag for metadata, and a documented cache purge procedure.

## Release gate

Do not enable v2 enforcement until all tests pass, a trusted public key is embedded, a secure signing process exists, and an actual signed IPA has been tested. Production publishing remains explicit and manually approved.
