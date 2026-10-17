#!/usr/bin/env python3
"""Offline Ed25519 public-key review and trust-store entry preparation.

Accepts only a PEM Ed25519 private key from an explicitly supplied local path
or a raw 32-byte public key. Never writes, displays or uploads private material.
Does not edit ZagUpdateTrustStore.swift or activate v2 updates.
"""
import argparse
import hashlib
import json
import re
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


def public_bytes(private_key=None, public_key=None):
    if (private_key is None) == (public_key is None):
        raise ValueError("Supply exactly one key input")
    if public_key is not None:
        result = public_key.read_bytes()
    else:
        key = serialization.load_pem_private_key(private_key.read_bytes(), password=None)
        if not isinstance(key, Ed25519PrivateKey):
            raise ValueError("Expected an Ed25519 private key")
        result = key.public_key().public_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PublicFormat.Raw)
    if len(result) != 32:
        raise ValueError("Ed25519 public key must be exactly 32 bytes")
    return result


def review(key, key_id):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", key_id, flags=re.ASCII):
        raise ValueError("Invalid key ID")
    return {
        "keyId": key_id,
        "algorithm": "Ed25519",
        "publicKeyHex": key.hex(),
        "publicKeySHA256": hashlib.sha256(key).hexdigest(),
        "swiftEntry": f'"{key_id}": Data([{", ".join("0x" + key[i:i+1].hex() for i in range(32))}])',
        "status": "REVIEW ONLY — NOT PROVISIONED",
    }


def main():
    parser = argparse.ArgumentParser()
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--private-key", type=Path, help="Local PEM key; only its public component is extracted")
    source.add_argument("--public-key", type=Path, help="32-byte raw Ed25519 public key")
    parser.add_argument("--key-id", required=True)
    parser.add_argument("--output", type=Path, help="Optional new JSON review file; never overwrites")
    args = parser.parse_args()
    try:
        result = review(public_bytes(args.private_key, args.public_key), args.key_id)
        encoded = json.dumps(result, indent=2, ensure_ascii=True) + "\n"
        if args.output:
            with args.output.open("x", encoding="utf-8") as file:
                file.write(encoded)
            print("PASS: public-only review file written:", args.output)
        else:
            print(encoded, end="")
        print("PASS: review-only public-key extraction; production trust unchanged")
    except (ValueError, OSError, TypeError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
