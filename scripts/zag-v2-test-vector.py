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
    print(json.dumps(vector, ensure_ascii=False, sort_keys=True, indent=2))

if __name__ == "__main__":
    main()
