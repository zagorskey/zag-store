#!/usr/bin/env python3
"""Test public-key review preparation using ephemeral Ed25519 keys."""
import hashlib
import importlib.util
import tempfile
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

spec = importlib.util.spec_from_file_location(
    "key_review", Path(__file__).with_name("prepare-zag-v2-public-key.py"))
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)


def main():
    with tempfile.TemporaryDirectory(prefix="zag-v2-key-review-") as directory:
        directory = Path(directory)
        private = Ed25519PrivateKey.generate()
        pem = directory / "disposable-private.pem"
        raw = directory / "disposable-public.raw"
        pem.write_bytes(private.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption()))
        raw.write_bytes(private.public_key().public_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PublicFormat.Raw))
        from_private = tool.public_bytes(private_key=pem)
        from_public = tool.public_bytes(public_key=raw)
        assert from_private == from_public
        print("PASS: private-key extraction matches independent raw public key")
        report = tool.review(from_public, "zag-v2-2026-a")
        assert report["publicKeySHA256"] == hashlib.sha256(from_public).hexdigest()
        assert report["publicKeyHex"] == from_public.hex()
        assert report["swiftEntry"].count("0x") == 32
        assert "REVIEW ONLY" in report["status"]
        print("PASS: SHA-256 fingerprint and 32-byte Swift entry")
        for bad in ("", "bad key", "a" * 65, "../secret"):
            try:
                tool.review(from_public, bad)
            except ValueError:
                continue
            raise AssertionError("Invalid key ID accepted")
        print("PASS: malformed key IDs rejected")
        raw.write_bytes(b"short")
        try:
            tool.public_bytes(public_key=raw)
        except ValueError:
            print("PASS: invalid public key length rejected")
        else:
            raise AssertionError("Invalid public key length accepted")
        print("SUCCESS: offline public-key provisioning preparation passed")


if __name__ == "__main__":
    main()
