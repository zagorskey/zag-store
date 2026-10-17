#!/usr/bin/env python3
"""Generate disposable Python-JCS-signed Unicode v2 fixture for Swift.

Never generates or touches production signing keys.
"""
import argparse
import datetime as dt
import json
from pathlib import Path
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from importlib.machinery import SourceFileLoader

signer = SourceFileLoader("zag_signer", str(Path(__file__).with_name("zag-sign-metadata-v2.py"))).load_module()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", type=Path, required=True)
    args = parser.parse_args()
    folder = args.directory.resolve()
    folder.mkdir(parents=True, exist_ok=True)
    key = Ed25519PrivateKey.generate()
    payload = {
        "schema": 2, "appId": "app.zagstore.ios", "channel": "beta",
        "sequence": 11, "version": "1.0.0", "build": "3",
        "minimumIOSVersion": "16.0",
        "ipaURL": "https://github.com/zagorskey/zag-store-releases/releases/download/test/ZagStore.ipa",
        "sha256": "a" * 64,
        "releaseNotes": "Обновяване — Café ☕ 日本語 🔐",
        "publishedAt": "2026-10-17T00:00:00Z",
        "expiresAt": "2026-10-18T00:00:00Z"
    }
    signed = signer.sign(payload, key, "disposable-python-jcs")
    public = key.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw
    )
    (folder / "envelope.json").write_bytes(json.dumps(
        signed, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("ascii"))
    (folder / "public-key.raw").write_bytes(public)
    print("PASS: disposable Python JCS Unicode fixture generated")
    print("Fixture directory:", folder)

if __name__ == "__main__":
    main()
