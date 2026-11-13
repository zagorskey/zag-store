# Changelog

This file tracks public Zag Store releases.

## 1.0.0 Beta 2 (build 2): 13 November 2026

Maintenance and update infrastructure release. [Release](https://github.com/zagorskey/zag-store/releases/tag/v1.0.0-beta.2)

- Beta channel update information is signed with the new key `zag-v2-2026-b`, which replaces the retired `zag-v2-2026-a`.
- Signature, expiry and anti-rollback checks stay in place, now with the new key.
- Clearer messages when update information has expired, isn't valid yet, or is signed with a key this version doesn't trust.
- Beta 1 can't verify the new key, so it won't offer this update in the app. Install Beta 2 manually; later Betas arrive in the app.

Unsigned IPA: `ZagStore-1.0.0-unsigned.ipa`, SHA-256 `5bb93c02230a97f3b4eb2c22e4f98ba15f4c5cf71602c2035de139ed81193cd6`. Its exact source is recorded in [Source provenance](docs/SOURCE-PROVENANCE.md).

## 1.0.0 Beta 1 (build 2): 15 October 2026

- First Zag Store beta: Stable, Beta and Nightly channel selection, and manual update checks.
