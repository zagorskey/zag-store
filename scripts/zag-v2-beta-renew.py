#!/usr/bin/env python3
"""Audit or locally renew Zag Store's authenticated Beta v2 metadata.

Audit needs no credentials. Renewal requires the EXISTING production Ed25519
private key as a local PEM file; it never uploads, prints or stores the key.
Publication is deliberately separate and requires operator review.
"""
import argparse
import base64
import datetime as dt
import hashlib
import json
import sys
import urllib.request
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

import importlib.util
MODULE = Path(__file__).with_name("zag-sign-metadata-v2.py")
spec = importlib.util.spec_from_file_location("zag_sign_metadata_v2", MODULE)
signer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signer)
sign, verify = signer.sign, signer.verify

URL = "https://raw.githubusercontent.com/zagorskey/zag-store-releases/main/releases/v2/beta.json"
KEY_ID = "zag-v2-2026-a"
PUBLIC_KEY_SHA256 = "1310a5ac9ccfbc82ac3f3dcb3e6eb1c90fd68fcb1efb3cbf59a647de04568e48"


def fetch():
    with urllib.request.urlopen(URL, timeout=15) as response:
        data = response.read(256 * 1024 + 1)
    if len(data) > 256 * 1024:
        raise ValueError("Manifest too large")
    envelope = json.loads(data)
    payload = json.loads(base64.b64decode(envelope["payload"], validate=True))
    if envelope["keyId"] != KEY_ID or payload["channel"] != "beta":
        raise ValueError("Unexpected key or channel")
    return envelope, payload


def timestamp(value):
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--renew", action="store_true", help="Generate locally signed successor (does not publish)")
    parser.add_argument("--private-key", type=Path, help="Existing production Ed25519 private PEM")
    parser.add_argument("--output", type=Path, help="New, nonexistent output JSON file")
    args = parser.parse_args()
    envelope, payload = fetch()
    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    expires = timestamp(payload["expiresAt"])
    remaining = expires - now
    print(f"Beta v2 sequence: {payload['sequence']}, version: {payload['version']} ({payload['build']})")
    print(f"Expires UTC: {payload['expiresAt']} | remaining: {remaining}")
    if not args.renew:
        if remaining <= dt.timedelta(0):
            print("CRITICAL: published signed metadata has expired", file=sys.stderr)
            return 2
        if remaining <= dt.timedelta(days=2):
            print("WARNING: renew within 48 hours", file=sys.stderr)
            return 1
        print("OK: metadata validity window is healthy")
        return 0

    if not args.private_key or not args.output:
        parser.error("--renew requires --private-key and --output")
    if args.output.exists():
        parser.error("Output exists: refusing overwrite")
    key = serialization.load_pem_private_key(args.private_key.read_bytes(), password=None)
    if not isinstance(key, Ed25519PrivateKey):
        raise ValueError("Expected Ed25519 private key")
    public = key.public_key()
    raw_public = public.public_bytes(Encoding.Raw, PublicFormat.Raw)
    if hashlib.sha256(raw_public).hexdigest() != PUBLIC_KEY_SHA256:
        raise ValueError("Private key does not match the pinned production trust root")
    # Validate the published predecessor's signature before reusing its
    # release identity and artifact digest. Expiry is expected during recovery.
    verify(envelope, public, "beta", now=min(now, expires - dt.timedelta(seconds=1)))
    successor = dict(payload)
    successor["sequence"] = payload["sequence"] + 1
    successor["publishedAt"] = now.isoformat().replace("+00:00", "Z")
    successor["expiresAt"] = (now + dt.timedelta(days=6)).isoformat().replace("+00:00", "Z")
    signed = sign(successor, key, KEY_ID)
    verify(signed, public, "beta", now=now)
    args.output.write_bytes(json.dumps(signed, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("ascii"))
    print(f"Signed successor sequence {successor['sequence']} at {args.output}")
    print("NOT PUBLISHED. Review artifact, then publish to the release repository.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(3)
