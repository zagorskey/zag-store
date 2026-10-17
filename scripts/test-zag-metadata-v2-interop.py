#!/usr/bin/env python3
"""Disposable Python Ed25519 -> macOS CryptoKit interoperability test.

Runs locally, never publishes metadata, and never writes a private key to disk.
Requires the isolated release-signing Python environment and Xcode's swift tool.
"""
import base64
import datetime as dt
import hashlib
import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("zag_sign_v2", ROOT / "zag-sign-metadata-v2.py")
signer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signer)

SWIFT = r"""
import Foundation
import CryptoKit

let envelopeURL = URL(fileURLWithPath: CommandLine.arguments[1])
let keyURL = URL(fileURLWithPath: CommandLine.arguments[2])
let raw = try Data(contentsOf: envelopeURL)
let key = try Data(contentsOf: keyURL)
guard key.count == 32 else { fatalError("Invalid test public key") }
let object = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
let payload = Data(base64Encoded: object["payload"] as! String)!
let signature = Data(base64Encoded: object["signature"] as! String)!
let domain = Data("ZAG-STORE-UPDATE-V2\\n".utf8)
let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key)
guard publicKey.isValidSignature(signature, for: domain + payload) else {
    fputs("FAIL: CryptoKit rejected Python signature\\n", stderr)
    exit(1)
}
print("PASS: CryptoKit accepted Python-generated Ed25519 signature")
"""

def main():
    key = Ed25519PrivateKey.generate()
    public = key.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    payload = {
        "schema": 2, "appId": "app.zagstore.ios", "channel": "beta",
        "sequence": 1, "version": "1.0.0", "build": "3",
        "minimumIOSVersion": "16.0",
        "ipaURL": "https://github.com/zagorskey/zag-store-releases/releases/download/test/ZagStore.ipa",
        "sha256": hashlib.sha256(b"disposable fixture").hexdigest(),
        "releaseNotes": "Disposable cross-language test",
        "publishedAt": now.isoformat().replace("+00:00", "Z"),
        "expiresAt": (now + dt.timedelta(days=1)).isoformat().replace("+00:00", "Z"),
    }
    envelope = signer.sign(payload, key, "disposable-test-key")
    assert signer.verify(envelope, key.public_key(), "beta") == payload
    with tempfile.TemporaryDirectory(prefix="zag-v2-interop-") as tmp:
        folder = Path(tmp)
        (folder / "verify.swift").write_text(SWIFT)
        (folder / "envelope.json").write_text(json.dumps(envelope))
        (folder / "public.key").write_bytes(public)
        subprocess.run(
            ["swift", str(folder / "verify.swift"),
             str(folder / "envelope.json"), str(folder / "public.key")],
            check=True,
        )
        altered = dict(envelope)
        altered["signature"] = base64.b64encode(b"0" * 64).decode()
        (folder / "envelope.json").write_text(json.dumps(altered))
        result = subprocess.run(
            ["swift", str(folder / "verify.swift"),
             str(folder / "envelope.json"), str(folder / "public.key")],
            capture_output=True, text=True,
        )
        if result.returncode == 0:
            raise AssertionError("CryptoKit accepted tampered signature")
        print("PASS: CryptoKit rejected tampered signature")
    print("SUCCESS: Python and CryptoKit Ed25519 interoperate")

if __name__ == "__main__":
    main()
