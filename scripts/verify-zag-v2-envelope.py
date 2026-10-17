#!/usr/bin/env python3
"""Offline independent v2 envelope verifier; no private keys or network access.

Usage: python3 scripts/verify-zag-v2-envelope.py --envelope FILE
       --public-key FILE --key-id ID --channel beta
       [--ipa FILE] [--now 2026-10-18T00:00:00Z]
"""
import argparse
import base64
import datetime as dt
import hashlib
import json
import sys
from pathlib import Path
from urllib.parse import urlsplit

import jcs
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

DOMAIN = b"ZAG-STORE-UPDATE-V2\n"
PAYLOAD_FIELDS = {
    "schema", "appId", "channel", "sequence", "version", "build",
    "minimumIOSVersion", "ipaURL", "sha256", "releaseNotes",
    "publishedAt", "expiresAt",
}
ENVELOPE_FIELDS = {"schema", "keyId", "payload", "signature"}
ALLOWED_CHANNELS = {"stable", "beta", "nightly"}


def strict_json(raw):
    def no_duplicates(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("Duplicate JSON key")
            result[key] = value
        return result
    return json.loads(raw, object_pairs_hook=no_duplicates,
                      parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)))


def canonical_base64(value):
    if not isinstance(value, str):
        raise ValueError("Invalid base64 type")
    raw = base64.b64decode(value, validate=True)
    if base64.b64encode(raw).decode("ascii") != value:
        raise ValueError("Noncanonical base64")
    return raw


def timestamp(value):
    if not isinstance(value, str) or not value.endswith("Z"):
        raise ValueError("Timestamp must end in Z")
    parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.utcoffset() != dt.timedelta(0):
        raise ValueError("Timestamp must be UTC")
    return parsed


def verify(envelope_bytes, public_bytes, key_id, channel, now, ipa=None):
    if len(envelope_bytes) > 256 * 1024:
        raise ValueError("Envelope too large")
    envelope = strict_json(envelope_bytes)
    if not isinstance(envelope, dict) or set(envelope) != ENVELOPE_FIELDS:
        raise ValueError("Unexpected envelope fields")
    if type(envelope["schema"]) is not int or envelope["schema"] != 2:
        raise ValueError("Invalid envelope schema")
    if envelope["keyId"] != key_id or not key_id or len(key_id.encode("utf-8")) > 64:
        raise ValueError("Untrusted key ID")
    if envelope_bytes != json.dumps(envelope, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("ascii"):
        raise ValueError("Noncanonical envelope")
    if len(public_bytes) != 32:
        raise ValueError("Public key must be 32 raw bytes")
    payload_bytes = canonical_base64(envelope["payload"])
    signature = canonical_base64(envelope["signature"])
    if len(signature) != 64:
        raise ValueError("Invalid signature length")
    Ed25519PublicKey.from_public_bytes(public_bytes).verify(signature, DOMAIN + payload_bytes)
    payload = strict_json(payload_bytes)
    if not isinstance(payload, dict) or set(payload) != PAYLOAD_FIELDS:
        raise ValueError("Unexpected payload fields")
    if jcs.canonicalize(payload) != payload_bytes:
        raise ValueError("Noncanonical payload")
    if type(payload["schema"]) is not int or payload["schema"] != 2:
        raise ValueError("Invalid payload schema")
    if payload["appId"] != "app.zagstore.ios" or payload["channel"] != channel or channel not in ALLOWED_CHANNELS:
        raise ValueError("Invalid app/channel")
    if type(payload["sequence"]) is not int or payload["sequence"] <= 0:
        raise ValueError("Invalid sequence")
    for field in ("version", "build", "minimumIOSVersion", "ipaURL", "releaseNotes"):
        if not isinstance(payload[field], str) or not payload[field]:
            raise ValueError("Invalid " + field)
    if not all(part.isascii() and part.isdigit() and part for part in payload["version"].split(".")):
        raise ValueError("Invalid version")
    if not payload["build"].isascii() or not payload["build"].isdigit():
        raise ValueError("Invalid build")
    if not all(part.isascii() and part.isdigit() and part for part in payload["minimumIOSVersion"].split(".")):
        raise ValueError("Invalid minimum iOS version")
    url = urlsplit(payload["ipaURL"])
    if (url.scheme != "https" or url.hostname != "github.com" or url.username or url.password
            or url.fragment or url.query or url.port
            or not url.path.startswith("/zagorskey/zag-store-releases/releases/download/")):
        raise ValueError("IPA URL not allowed")
    sha = payload["sha256"]
    if not isinstance(sha, str) or len(sha) != 64 or any(c not in "0123456789abcdef" for c in sha):
        raise ValueError("Invalid IPA checksum")
    published, expires = timestamp(payload["publishedAt"]), timestamp(payload["expiresAt"])
    if not published <= now < expires or expires <= published or expires - published > dt.timedelta(days=7):
        raise ValueError("Invalid metadata lifetime")
    if ipa is not None:
        digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
        if digest != sha:
            raise ValueError("IPA SHA-256 mismatch")
    return payload


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--envelope", type=Path, required=True)
    parser.add_argument("--public-key", type=Path, required=True)
    parser.add_argument("--key-id", required=True)
    parser.add_argument("--channel", choices=sorted(ALLOWED_CHANNELS), required=True)
    parser.add_argument("--ipa", type=Path)
    parser.add_argument("--now", help="UTC ISO8601 timestamp; defaults to current UTC time")
    args = parser.parse_args()
    try:
        now = timestamp(args.now) if args.now else dt.datetime.now(dt.timezone.utc)
        result = verify(args.envelope.read_bytes(), args.public_key.read_bytes(),
                        args.key_id, args.channel, now, args.ipa)
        print("PASS: offline independent Ed25519 envelope and canonical payload verification")
        print("PASS: key ID, channel, timestamps, URL and SHA-256 syntax")
        if args.ipa:
            print("PASS: local IPA SHA-256 matches signed manifest")
        print("Sequence:", result["sequence"])
    except Exception as error:
        print("FAIL:", error, file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
