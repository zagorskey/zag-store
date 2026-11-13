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
TRUST_STORE = Path(__file__).resolve().parent.parent / "Feather/Utilities/ZagUpdateTrustStore.swift"
# Public keys that signed published manifests but are no longer in the app's
# trust store. Used only to verify a predecessor, never to sign.
RETIRED_KEYS = {
    "zag-v2-2026-a": bytes.fromhex("97c762c6062134d6c38129751029463e0ad51f56a2a473e5cc0fa937d2d12d6c"),
}


def trusted_keys():
    """Key ID -> raw public key, read from the app's own trust store."""
    import re
    source = TRUST_STORE.read_text()
    keys = {}
    for key_id, body in re.findall(r'"([A-Za-z0-9._-]+)":\s*Data\(\[([^\]]*)\]\)', source):
        raw = bytes(int(b, 16) for b in re.findall(r"0x([0-9a-fA-F]{2})", body))
        if len(raw) != 32:
            raise ValueError(f"Trust-store key {key_id} is not 32 bytes")
        keys[key_id] = raw
    if not keys:
        raise ValueError("No keys found in the trust store")
    return keys


def fetch():
    with urllib.request.urlopen(URL, timeout=15) as response:
        data = response.read(256 * 1024 + 1)
    if len(data) > 256 * 1024:
        raise ValueError("Manifest too large")
    envelope = json.loads(data)
    payload = json.loads(base64.b64decode(envelope["payload"], validate=True))
    if envelope["keyId"] not in {**RETIRED_KEYS, **trusted_keys()} or payload["channel"] != "beta":
        raise ValueError("Unexpected key or channel")
    return envelope, payload


def timestamp(value):
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def new_release(args, previous):
    """Release fields for a new IPA. The build number is the app's own
    (CFBundleVersion); only the metadata sequence must increase."""
    import plistlib
    import zipfile
    if not args.ipa_url or not args.notes:
        raise ValueError("--release-ipa requires --ipa-url and --notes")
    prefix = "https://github.com/zagorskey/zag-store-releases/releases/download/"
    if not args.ipa_url.startswith(prefix):
        raise ValueError("IPA URL must be a zag-store-releases download URL")
    data = args.release_ipa.read_bytes()
    with zipfile.ZipFile(args.release_ipa) as ipa:
        names = ipa.namelist()
        plists = [n for n in names if n.count("/") == 2 and n.startswith("Payload/") and n.endswith(".app/Info.plist")]
        if len(plists) != 1:
            raise ValueError("Expected one Payload/*.app/Info.plist")
        app = plists[0].rsplit("/", 1)[0]
        if app + "/embedded.mobileprovision" in names:
            raise ValueError("IPA contains a provisioning profile; publish only the unsigned IPA")
        info = plistlib.loads(ipa.read(plists[0]))
    if info.get("CFBundleIdentifier") != "app.zagstore.ios":
        raise ValueError("Unexpected bundle identifier")
    notes = args.notes.read_text(encoding="utf-8").strip()
    if not notes:
        raise ValueError("Release notes are empty")
    release = {
        "version": info["CFBundleShortVersionString"],
        "build": info["CFBundleVersion"],
        "minimumIOSVersion": info["MinimumOSVersion"],
        "ipaURL": args.ipa_url,
        "sha256": hashlib.sha256(data).hexdigest(),
        "releaseNotes": notes,
    }
    print(f"New release: {release['version']} ({release['build']}) sha256 {release['sha256']}")
    if release["sha256"] == previous["sha256"]:
        raise ValueError("IPA is identical to the published release")
    return release


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--renew", action="store_true", help="Generate locally signed successor (does not publish)")
    parser.add_argument("--private-key", type=Path, help="Production Ed25519 private PEM (may be passphrase-encrypted)")
    parser.add_argument("--key-id", help="With --renew: the trust-store key ID the private key belongs to")
    parser.add_argument("--output", type=Path, help="New, nonexistent output JSON file")
    parser.add_argument("--release-ipa", type=Path, help="With --renew: sign a NEW release from this local IPA instead of renewing the current one")
    parser.add_argument("--ipa-url", help="With --release-ipa: its public zag-store-releases download URL")
    parser.add_argument("--notes", type=Path, help="With --release-ipa: UTF-8 release notes file")
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

    if not args.private_key or not args.output or not args.key_id:
        parser.error("--renew requires --private-key, --key-id and --output")
    if args.output.exists():
        parser.error("Output exists: refusing overwrite")
    trusted = trusted_keys()
    if args.key_id not in trusted:
        parser.error(f"{args.key_id} is not in {TRUST_STORE.name}")
    pem = args.private_key.read_bytes()
    try:
        key = serialization.load_pem_private_key(pem, password=None)
    except TypeError:
        import getpass
        key = serialization.load_pem_private_key(pem, password=getpass.getpass("Key passphrase: ").encode())
    if not isinstance(key, Ed25519PrivateKey):
        raise ValueError("Expected Ed25519 private key")
    public = key.public_key()
    if public.public_bytes(Encoding.Raw, PublicFormat.Raw) != trusted[args.key_id]:
        raise ValueError(f"Private key does not match trust-store key {args.key_id}")
    # Validate the published predecessor's signature, with the key that signed
    # it, before reusing its release identity. Expiry is expected in recovery.
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    previous_key = Ed25519PublicKey.from_public_bytes({**RETIRED_KEYS, **trusted}[envelope["keyId"]])
    verify(envelope, previous_key, "beta", now=min(now, expires - dt.timedelta(seconds=1)))
    if envelope["keyId"] != args.key_id and not args.release_ipa:
        parser.error("Changing keys needs --release-ipa: a build that trusts the new key must be released with it")
    successor = dict(payload)
    successor["sequence"] = payload["sequence"] + 1
    if args.release_ipa:
        successor.update(new_release(args, payload))
    successor["publishedAt"] = now.isoformat().replace("+00:00", "Z")
    successor["expiresAt"] = (now + dt.timedelta(days=6)).isoformat().replace("+00:00", "Z")
    signed = sign(successor, key, args.key_id)
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
