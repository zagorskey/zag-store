# Authenticated metadata v2 — production-readiness security review

**Status:** Offline prototype tests green (33 integration checks, 18 persistence checks, 20/20 multiprocess stress runs reported on macOS). **NOT cleared for production**. Do not enable authenticated v2 in the live updater, publish v2 manifests, or provision production keys based on these results alone.

## P0 blockers before production activation

1. **Trust-root provisioning and key lifecycle:** `ZagMetadataV2KeyRegistry.production()` intentionally contains no anchors. Establish an offline signing ceremony, protect private keys, publish audited public key identifiers in app builds, and document compromise/revocation/rotation. Never derive trusted keys from an untrusted manifest.
2. **Canonical JSON parsing:** `ZagMetadataV2TestVerifier.isCanonicalFlatPayload` uses a custom byte scanner plus Foundation serialization, not a validated complete RFC 8785 implementation. Replace or formally constrain/audit it; fuzz duplicate keys, Unicode, escapes, malformed UTF-8, oversized values, and integer overflow. Enforce canonical base64 and strict envelope parsing.
3. **Artifact binding:** The offline coordinator records a verified metadata sequence but does not download/check the IPA. Production must verify the **downloaded IPA's actual SHA-256** against the *authenticated* digest, as well as enforce the intended bundle ID, team/signing identity, entitlements and installation authorization before install. Do not advance accepted state before a defined successful download/verification/install phase.
4. **Durable anti-rollback state:** Current persistence is a local JSON snapshot protected by cooperative `flock` and atomic replacement. Harden symlink/path ownership and file permissions (`O_NOFOLLOW`, protected container), handling interrupted writes, `fsync` semantics, file-lock errors and path aliasing. A missing state file is accepted as new installation; deleting/restoring app state can reset protection. Define backup/reinstall policy and cross-channel downgrade rules.
5. **Transport/migration fail-closed policy:** Design a bounded v1-to-v2 transition with a persistent migration floor, separate endpoints, no fallback to v1 after v2 authentication failure, and correctly scoped cache expiration. Test loss of network, stale CDN content and truncated downloads.

## P1 release engineering / quality gates

- **Signer/publisher validation parity:** Python signer URL validation is a prefix check, less strict than Swift's URI requirements. Align both to identical canonical URL rules; also align timestamp validation (including not-yet-published).
- **Production release workflow:** Existing `scripts/publish-zag-release.zsh` still emits legacy v1 metadata. Add separate dry-run-only v2 publishing steps and artifact immutability/sequence allocation tests before any authorized v2 publication.
- **Adversarial testing:** Property-based malformed payload/fuzz testing; test malformed envelopes including duplicate envelope keys; cross-process lock failure injection, disk full/crash recovery, symlink attacks, concurrent readers/writers, and negative installation-path tests.
- **Device acceptance:** Verify on iOS with signed Beta IPA and staging metadata after the above blockers are fixed, with monitored rollback plan and no production key exposure.

## Gate to resume live integration

A reviewed production verifier + trust registry, signed artifact hash and identity verification, durable replay guarantees, explicit migration policy, reproducible builds and adversarial tests must all be demonstrated. Until then, keep v2 isolated in `scripts/` and preserve the live updater.
