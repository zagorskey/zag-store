#!/usr/bin/env python3
"""Offline Zag Store v2 signing utility. No network calls or production keys.

Requires: python3 -m pip install -r scripts/requirements-release-signing.txt
Use only a disposable test key for 'self-test'. Production keys must be supplied
via a protected filesystem path and must never be checked into source control.
"""
import argparse
import base64
import datetime as dt
import hashlib
import json
from pathlib import Path

import jcs
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey

PREFIX = b"ZAG-STORE-UPDATE-V2\n"
FIELDS = {
    "schema", "appId", "channel", "sequence", "version", "build",
    "minimumIOSVersion", "ipaURL", "sha256", "releaseNotes",
    "publishedAt", "expiresAt",
}


def strict_json(data: bytes):
    def unique(pairs):
        obj = {}
        for key, value in pairs:
            if key in obj:
                raise ValueError(f"Duplicate JSON key: {key}")
            obj[key] = value
        return obj
    return json.loads(data, object_pairs_hook=unique, parse_constant=lambda x: (_ for _ in ()).throw(ValueError(x)))


def validate_payload(payload):
    if not isinstance(payload, dict) or set(payload) != FIELDS:
        raise ValueError("Unexpected or missing payload fields")
    if type(payload["schema"]) is not int or payload["schema"] != 2:
        raise ValueError("Invalid schema")
    if payload["appId"] != "app.zagstore.ios" or payload["channel"] not in ("stable", "beta", "nightly"):
        raise ValueError("Invalid app or channel")
    if type(payload["sequence"]) is not int or payload["sequence"] < 1:
        raise ValueError("Invalid sequence")
    for name in ("version", "build", "minimumIOSVersion", "ipaURL", "releaseNotes"):
        if not isinstance(payload[name], str) or not payload[name]:
            raise ValueError(f"Invalid {name}")
    if not all(x.isdigit() for x in payload["version"].split(".")) or not payload["build"].isascii() or not payload["build"].isdigit():
        raise ValueError("Invalid version/build")
    if not payload["ipaURL"].startswith("https://github.com/zagorskey/zag-store-releases/releases/download/"):
        raise ValueError("IPA origin not allowed")
    sha = payload["sha256"]
    if not isinstance(sha, str) or len(sha) != 64 or any(c not in "0123456789abcdef" for c in sha):
        raise ValueError("Invalid checksum")
    dates = []
    for key in ("publishedAt", "expiresAt"):
        value = payload[key]
        if not isinstance(value, str) or not value.endswith("Z"):
            raise ValueError("Invalid timestamp")
        dates.append(dt.datetime.fromisoformat(value.replace("Z", "+00:00")))
    if not dates[0] < dates[1] or dates[1] - dates[0] > dt.timedelta(days=7):
        raise ValueError("Invalid metadata lifetime")


def b64decode(value):
    if not isinstance(value, str):
        raise ValueError("Invalid base64")
    decoded = base64.b64decode(value, validate=True)
    if base64.b64encode(decoded).decode() != value:
        raise ValueError("Noncanonical base64")
    return decoded


def sign(payload, private_key, key_id):
    validate_payload(payload)
    if not key_id or not isinstance(key_id, str):
        raise ValueError("Missing key ID")
    raw = jcs.canonicalize(payload)
    signature = private_key.sign(PREFIX + raw)
    return {"schema": 2, "keyId": key_id,
            "payload": base64.b64encode(raw).decode(),
            "signature": base64.b64encode(signature).decode()}


def verify(envelope, public_key, expected_channel, now=None):
    if not isinstance(envelope, dict) or set(envelope) != {"schema", "keyId", "payload", "signature"} or envelope["schema"] != 2:
        raise ValueError("Invalid envelope")
    raw = b64decode(envelope["payload"])
    signature = b64decode(envelope["signature"])
    if len(signature) != 64:
        raise ValueError("Invalid signature length")
    payload = strict_json(raw)
    if jcs.canonicalize(payload) != raw:
        raise ValueError("Noncanonical payload")
    public_key.verify(signature, PREFIX + raw)
    validate_payload(payload)
    if payload["channel"] != expected_channel:
        raise ValueError("Channel mismatch")
    now = now or dt.datetime.now(dt.timezone.utc)
    if now >= dt.datetime.fromisoformat(payload["expiresAt"].replace("Z", "+00:00")):
        raise ValueError("Expired metadata")
    return payload


def self_test():
    private = Ed25519PrivateKey.generate()
    public = private.public_key()
    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    payload = {
        "schema": 2, "appId": "app.zagstore.ios", "channel": "beta",
        "sequence": 1, "version": "1.0.0", "build": "3",
        "minimumIOSVersion": "16.0",
        "ipaURL": "https://github.com/zagorskey/zag-store-releases/releases/download/test/ZagStore.ipa",
        "sha256": hashlib.sha256(b"test IPA").hexdigest(),
        "releaseNotes": "Disposable test only",
        "publishedAt": now.isoformat().replace("+00:00", "Z"),
        "expiresAt": (now + dt.timedelta(days=1)).isoformat().replace("+00:00", "Z"),
    }
    envelope = sign(payload, private, "test-key")
    assert verify(envelope, public, "beta") == payload
    print("PASS: Valid signature")
    for name, changed in [
        ("Tampered signature", {**envelope, "signature": base64.b64encode(b"0"*64).decode()}),
        ("Tampered payload", {**envelope, "payload": base64.b64encode(jcs.canonicalize({**payload, "build": "4"})).decode()}),
    ]:
        try:
            verify(changed, public, "beta")
            raise AssertionError(name + " accepted")
        except InvalidSignature:
            print("PASS:", name, "rejected")
    try:
        verify(envelope, public, "stable")
        raise AssertionError("Wrong channel accepted")
    except ValueError:
        print("PASS: Wrong channel rejected")
    try:
        verify(envelope, public, "beta", now + dt.timedelta(days=2))
        raise AssertionError("Expired manifest accepted")
    except ValueError:
        print("PASS: Expired metadata rejected")
    print("SUCCESS: Offline v2 signing smoke tests passed")


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("self-test")
    signer = sub.add_parser("sign")
    signer.add_argument("--payload", type=Path, required=True)
    signer.add_argument("--private-key", type=Path, required=True)
    signer.add_argument("--key-id", required=True)
    signer.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "self-test":
        self_test()
    else:
        if args.output.exists():
            parser.error("Output exists; refusing overwrite")
        key = serialization.load_pem_private_key(args.private_key.read_bytes(), password=None)
        if not isinstance(key, Ed25519PrivateKey):
            parser.error("Expected Ed25519 private key")
        payload = strict_json(args.payload.read_bytes())
        envelope = sign(payload, key, args.key_id)
        args.output.write_text(json.dumps(envelope, indent=2, ensure_ascii=False) + "\n")
        print("Signed manifest written:", args.output)


if __name__ == "__main__":
    main()
