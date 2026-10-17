#!/usr/bin/env python3
"""Generate reproducible, NON-PRODUCTION v2 Ed25519 test vectors.

The seed below is intentionally public. Never use this key to publish releases.
"""
import base64
import hashlib
import json

import jcs
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from importlib.machinery import SourceFileLoader
from pathlib import Path

signer = SourceFileLoader("zag_sign_v2", str(Path(__file__).with_name("zag-sign-metadata-v2.py"))).load_module()
TEST_SEED = bytes(range(32))
TEST_KEY_ID = "zag-v2-test-only"

def fixture():
    private = Ed25519PrivateKey.from_private_bytes(TEST_SEED)
    public = private.public_key().public_bytes_raw()
    payload = {
        "schema": 2,
        "appId": "com.cwd43.gu29",
        "channel": "beta",
        "sequence": 7,
        "version": "1.0.1",
        "build": "7",
        "minimumIOSVersion": "16.0",
        "ipaURL": "https://github.com/zagorskey/zag-store-releases/releases/download/v1.0.1-beta.build7/ZagStore.ipa",
        "sha256": hashlib.sha256(b"NOT AN ACTUAL IPA").hexdigest(),
        "releaseNotes": "Offline test vector — NOT a publishable release",
        "publishedAt": "2026-10-17T10:00:00Z",
        "expiresAt": "2026-10-20T10:00:00Z",
    }
    envelope = signer.sign(payload, private, TEST_KEY_ID)
    return {
        "warning": "PUBLIC TEST KEY — NEVER TRUST IN PRODUCTION",
        "keyId": TEST_KEY_ID,
        "publicKeyBase64": base64.b64encode(public).decode("ascii"),
        "envelope": envelope,
        "payload": payload,
    }

def signed_negative_cases():
    """Deliberately bypass publisher validation to test the client independently."""
    private = Ed25519PrivateKey.from_private_bytes(TEST_SEED)
    base = fixture()["payload"]
    cases = {}
    mutations = {
        "unknownPayloadField": {**base, "unexpected": "reject"},
        "missingPayloadField": {k: v for k, v in base.items() if k != "releaseNotes"},
        "invalidChecksum": {**base, "sha256": "z" * 64},
        "zeroSequence": {**base, "sequence": 0},
        "wrongAppId": {**base, "appId": "com.example.other"},
        "invalidVersion": {**base, "version": "1.0.beta"},
        "invalidBuild": {**base, "build": "7beta"},
        "invalidMinimumIOS": {**base, "minimumIOSVersion": "iOS16"},
        "insecureIPAURL": {**base, "ipaURL": "http://github.com/zagorskey/zag-store-releases/releases/download/x/ZagStore.ipa"},
        "wrongIPAHost": {**base, "ipaURL": "https://github.com.evil.example/releases/download/x/ZagStore.ipa"},
        "credentialedIPAURL": {**base, "ipaURL": "https://user:pass@github.com/zagorskey/zag-store-releases/releases/download/x/ZagStore.ipa"},
        "unexpectedIPAPort": {**base, "ipaURL": "https://github.com:8443/zagorskey/zag-store-releases/releases/download/x/ZagStore.ipa"},
        "ipaURLWithFragment": {**base, "ipaURL": "https://github.com/zagorskey/zag-store-releases/releases/download/v1.0.1-beta.build7/ZagStore.ipa#alternate"},
        "ipaURLWithQuery": {**base, "ipaURL": "https://github.com/zagorskey/zag-store-releases/releases/download/v1.0.1-beta.build7/ZagStore.ipa?download=1"},
        "encodedPathSeparator": {**base, "ipaURL": "https://github.com/zagorskey/zag-store-releases/releases/download%2Fother/ZagStore.ipa"},
        "encodedBackslash": {**base, "ipaURL": "https://github.com/zagorskey/zag-store-releases/releases/download/x%5Cother/ZagStore.ipa"},
        "missingReleaseAsset": {**base, "ipaURL": "https://github.com/zagorskey/zag-store-releases/releases/download/only-tag"},
        "emptyReleaseTag": {**base, "ipaURL": "https://github.com/zagorskey/zag-store-releases/releases/download//ZagStore.ipa"},
        "ipaPathTraversal": {**base, "ipaURL": "https://github.com/zagorskey/zag-store-releases/releases/download/../other/ZagStore.ipa"},
        "encodedDotDotTraversal": {**base, "ipaURL": "https://github.com/zagorskey/zag-store-releases/releases/download/%2E%2E/other/ZagStore.ipa"},
        "futurePublication": {**base, "publishedAt": "2026-10-19T10:00:00Z"},
        "tooLongLifetime": {**base, "expiresAt": "2026-11-20T10:00:00Z"},
    }
    for name, payload in mutations.items():
        raw = jcs.canonicalize(payload)
        cases[name] = {
            "schema": 2,
            "keyId": TEST_KEY_ID,
            "payload": base64.b64encode(raw).decode("ascii"),
            "signature": base64.b64encode(
                private.sign(signer.PREFIX + raw)).decode("ascii"),
        }
    # These payloads have valid signatures over deliberately noncanonical JSON.
    # They must be rejected even though their decoded values look acceptable.
    raw_cases = {
        "noncanonicalWhitespace": json.dumps(base, ensure_ascii=False, indent=2).encode("utf-8"),
        "duplicatePayloadKey": jcs.canonicalize(base)[:-1] + b',"sequence":7}',
        "reorderedKeys": json.dumps(base, ensure_ascii=False, separators=(",", ":")).encode("utf-8"),
        "escapedSlash": jcs.canonicalize(base).replace(b"https://", b"https:" + bytes([92, 47, 92, 47])),
        "escapedUnicode": jcs.canonicalize({**base, "releaseNotes": "café"}).replace(bytes([195, 169]), bytes([92]) + b"u00e9"),
    }
    # Signed malformed UTF-8 and an integer outside Swift's Int range.
    # These inputs bypass the publisher deliberately to exercise the verifier.
    raw_cases["invalidUTF8"] = (
        jcs.canonicalize(base).replace(b"Offline test vector", b"Offline " + bytes([0xff]) + b" test vector")
    )
    raw_cases["oversizedSequence"] = (
        jcs.canonicalize(base).replace(b'"sequence":7', b'"sequence":9223372036854775808')
    )
    for name, raw in raw_cases.items():
        cases[name] = {
            "schema": 2,
            "keyId": TEST_KEY_ID,
            "payload": base64.b64encode(raw).decode("ascii"),
            "signature": base64.b64encode(
                private.sign(signer.PREFIX + raw)).decode("ascii"),
        }
    return cases


def main():
    vector = fixture()
    canonical = jcs.canonicalize(vector["payload"])
    assert base64.b64decode(vector["envelope"]["payload"]) == canonical
    assert signer.verify(
        vector["envelope"],
        Ed25519PrivateKey.from_private_bytes(TEST_SEED).public_key(),
        "beta",
        now=__import__("datetime").datetime.fromisoformat("2026-10-18T00:00:00+00:00"),
    ) == vector["payload"]
    # Deterministic local artifact bytes with a matching authenticated digest.
    # This is NOT a ZIP/IPA and must never be considered installable.
    artifact_bytes = b"ZAG-V2-DISPOSABLE-ARTIFACT-TEST\\n" + bytes(range(256)) * 4
    vector["signedArtifactPositive"] = {
        "bytesBase64": base64.b64encode(artifact_bytes).decode("ascii"),
        "envelope": signer.sign(
            {**vector["payload"], "sha256": hashlib.sha256(artifact_bytes).hexdigest()},
            Ed25519PrivateKey.from_private_bytes(TEST_SEED), TEST_KEY_ID),
    }
    vector["signedPositiveCases"] = {
        "emojiAndControls": signer.sign(
            {**vector["payload"], "releaseNotes": "Update 🚀 — line one\nline two\t✓"},
            Ed25519PrivateKey.from_private_bytes(TEST_SEED), TEST_KEY_ID),

        "bulgarianNotes": signer.sign(
            {**vector["payload"], "releaseNotes": "Нова версия — подобрения"},
            Ed25519PrivateKey.from_private_bytes(TEST_SEED), TEST_KEY_ID),
    }
    # A second valid signature over different content at the same sequence.
    # Verification must succeed, but persistence must reject the conflict.
    vector["signedEqualSequenceConflict"] = signer.sign(
        {**vector["payload"], "releaseNotes": "Different authenticated release at sequence seven"},
        Ed25519PrivateKey.from_private_bytes(TEST_SEED), TEST_KEY_ID)
    vector["signedHigherSequence"] = signer.sign(
        {**vector["payload"], "sequence": 8, "build": "8"},
        Ed25519PrivateKey.from_private_bytes(TEST_SEED), TEST_KEY_ID)
    ROTATED_TEST_SEED = bytes(reversed(range(32)))
    rotated_private = Ed25519PrivateKey.from_private_bytes(ROTATED_TEST_SEED)
    vector["rotatedPublicKeyBase64"] = base64.b64encode(
        rotated_private.public_key().public_bytes_raw()).decode("ascii")
    vector["signedRotatedKeyUpgrade"] = signer.sign(
        {**vector["payload"], "sequence": 9, "build": "9"},
        rotated_private, "zag-v2-rotated-test-only")
    # Differential corpus: the reference JCS serializer defines the accepted
    # bytes. Mutations are signed independently so Swift cannot reject them
    # merely because a signature is invalid. Stable, reproducible corpus.
    differentials = {}
    private = Ed25519PrivateKey.from_private_bytes(TEST_SEED)
    for index, notes in enumerate([
        "", "ASCII release", "café", "Нова версия", "🚀 launch",
        "line one" + chr(10) + "line two",
        "slash / and backslash " + chr(92),
        "quote " + chr(34) + " and tab" + chr(9),
        "accent e" + chr(0x0301), "控制字符",
    ]):
        candidate = {**vector["payload"], "releaseNotes": notes}
        canonical = jcs.canonicalize(candidate)
        variants = {
            "canonical": canonical,
            "spaced": json.dumps(candidate, ensure_ascii=False, indent=1).encode("utf-8"),
            "unsorted": json.dumps(candidate, ensure_ascii=False, separators=(",", ":")).encode("utf-8"),
            "asciiEscaped": json.dumps(candidate, ensure_ascii=True, sort_keys=True, separators=(",", ":")).encode("utf-8"),
        }
        for variant, raw in variants.items():
            key = f"{index:02d}-{variant}"
            differentials[key] = {
                "expectedAccepted": raw == canonical,
                "envelope": {
                    "schema": 2,
                    "keyId": TEST_KEY_ID,
                    "payload": base64.b64encode(raw).decode("ascii"),
                    "signature": base64.b64encode(private.sign(signer.PREFIX + raw)).decode("ascii"),
                },
            }
    vector["canonicalDifferentialCases"] = differentials
    vector["signedNegativeCases"] = signed_negative_cases()
    print(json.dumps(vector, ensure_ascii=False, sort_keys=True, indent=2))

if __name__ == "__main__":
    main()
