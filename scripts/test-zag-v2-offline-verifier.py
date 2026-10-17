#!/usr/bin/env python3
"""Exercise offline v2 verifier using an ephemeral Ed25519 key only."""
import base64
import datetime as dt
import hashlib
import importlib.util
import json
import tempfile
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    signer = load("zag_sign", "zag-sign-metadata-v2.py")
    verifier = load("zag_verify", "verify-zag-v2-envelope.py")
    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    with tempfile.TemporaryDirectory(prefix="zag-v2-offline-") as directory:
        ipa = Path(directory) / "disposable.ipa"
        ipa.write_bytes(b"disposable test bytes, not a real IPA")
        private = Ed25519PrivateKey.generate()
        public = private.public_key().public_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PublicFormat.Raw)
        payload = {
            "schema": 2, "appId": "app.zagstore.ios", "channel": "beta",
            "sequence": 17, "version": "2.9.0", "build": "2",
            "minimumIOSVersion": "16.0",
            "ipaURL": "https://github.com/zagorskey/zag-store-releases/releases/download/test/ZagStore.ipa",
            "sha256": hashlib.sha256(ipa.read_bytes()).hexdigest(),
            "releaseNotes": "Обновяване — Café ☕ 日本語 🔐",
            "publishedAt": (now - dt.timedelta(minutes=1)).isoformat().replace("+00:00", "Z"),
            "expiresAt": (now + dt.timedelta(days=1)).isoformat().replace("+00:00", "Z"),
        }
        envelope = signer.sign(payload, private, "disposable-offline")
        encoded = json.dumps(envelope, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("ascii")
        verifier.verify(encoded, public, "disposable-offline", "beta", now, ipa)
        print("PASS: disposable Python signer verified independently")
        print("PASS: Unicode notes and local IPA checksum verified")

        def rejects(name, value, key=public, channel="beta", file=ipa):
            try:
                verifier.verify(value, key, "disposable-offline", channel, now, file)
            except Exception:
                print("PASS:", name, "rejected")
                return
            raise AssertionError(name + " accepted")

        changed = dict(envelope)
        changed["signature"] = base64.b64encode(b"0" * 64).decode()
        rejects("forged signature", json.dumps(changed, sort_keys=True, separators=(",", ":")).encode())
        changed = dict(envelope)
        changed["payload"] = base64.b64encode(b"{}").decode()
        rejects("tampered payload", json.dumps(changed, sort_keys=True, separators=(",", ":")).encode())
        rejects("wrong channel", encoded, channel="stable")
        rejects("wrong public key", encoded, key=Ed25519PrivateKey.generate().public_key().public_bytes(
            encoding=serialization.Encoding.Raw, format=serialization.PublicFormat.Raw))
        ipa.write_bytes(b"tampered IPA")
        rejects("IPA checksum mismatch", encoded)
        print("SUCCESS: offline v2 signing verification checks passed")


if __name__ == "__main__":
    main()
