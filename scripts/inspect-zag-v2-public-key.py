#!/usr/bin/env python3
"""Offline, read-only Ed25519 public trust-anchor inspection.

Accepts ONLY a public PEM key. Never reads or generates a private signing key.
Prints a Swift-ready public-key constant for manual code review; does not edit
the app or activate v2 updates.
"""
import argparse
import base64
import hashlib
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--public-key", required=True, type=Path)
    parser.add_argument("--key-id", required=True)
    args = parser.parse_args()

    if not args.key_id.isascii() or not args.key_id or len(args.key_id) > 64:
        parser.error("key ID must be nonempty ASCII (max 64 characters)")
    if not all(c.isalnum() or c in "-_." for c in args.key_id):
        parser.error("key ID may contain only ASCII letters, digits, hyphens, underscores and dots")
    public = serialization.load_pem_public_key(args.public_key.read_bytes())
    if not isinstance(public, Ed25519PublicKey):
        parser.error("expected an Ed25519 PUBLIC key (not a private key)")
    raw = public.public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    assert len(raw) == 32
    print("Key ID:", args.key_id)
    print("Public key SHA-256 fingerprint:", hashlib.sha256(raw).hexdigest())
    print("Public key base64:", base64.b64encode(raw).decode())
    print("Swift trust anchor (review before committing):")
    print(f'    "{args.key_id}": Data(base64Encoded: "{base64.b64encode(raw).decode()}")!')
    print("No key was installed and no update channel was modified.")


if __name__ == "__main__":
    main()
