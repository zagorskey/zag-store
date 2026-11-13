#!/usr/bin/env python3
"""Generate a Zag Store update-metadata Ed25519 signing key, offline.

Run only after the release owner approves a new key. Writes, into a new
directory outside any Git checkout:
  <key-id>.private.pem   passphrase-encrypted PKCS#8 private key (0600)
  <key-id>.public.pem    public key
  <key-id>.json          key ID, fingerprint, creation time (no secrets)
Prints the public fingerprint and the trust-store line for review. Never
prints, uploads or stores the private key or passphrase anywhere else.
Copy the whole directory to the recovery backup before using the key.
"""
import argparse
import datetime as dt
import getpass
import hashlib
import json
import os
import re
import socket
import subprocess
import sys
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat


def online():
    try:
        socket.create_connection(("1.1.1.1", 443), timeout=2).close()
        return True
    except OSError:
        return False


def inside_git(path):
    result = subprocess.run(["git", "-C", str(path), "rev-parse", "--is-inside-work-tree"],
                            capture_output=True, text=True)
    return result.returncode == 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--key-id", required=True, help="New key ID, e.g. zag-v2-2026-b")
    parser.add_argument("--out-dir", required=True, type=Path, help="New directory, outside any Git checkout")
    parser.add_argument("--allow-online", action="store_true", help="Proceed although the network is reachable")
    args = parser.parse_args()

    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", args.key_id, flags=re.ASCII):
        parser.error("invalid key ID")
    if args.key_id == "zag-v2-2026-a":
        parser.error("zag-v2-2026-a is the original key; choose a new key ID")
    out = args.out_dir.expanduser().resolve()
    if out.exists():
        parser.error(f"{out} exists: refusing to overwrite")
    if inside_git(out.parent):
        parser.error("output directory is inside a Git checkout")
    if online() and not args.allow_online:
        parser.error("network is reachable: disconnect first, or pass --allow-online")

    passphrase = getpass.getpass("New key passphrase (16+ characters): ")
    if len(passphrase) < 16:
        parser.error("passphrase too short")
    if getpass.getpass("Repeat passphrase: ") != passphrase:
        parser.error("passphrases differ")

    key = Ed25519PrivateKey.generate()
    raw = key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    fingerprint = hashlib.sha256(raw).hexdigest()
    out.mkdir(mode=0o700, parents=False)
    private = out / f"{args.key_id}.private.pem"
    fd = os.open(private, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as handle:
        handle.write(key.private_bytes(
            Encoding.PEM, serialization.PrivateFormat.PKCS8,
            serialization.BestAvailableEncryption(passphrase.encode())))
    (out / f"{args.key_id}.public.pem").write_bytes(
        key.public_key().public_bytes(Encoding.PEM, PublicFormat.SubjectPublicKeyInfo))
    record = {
        "keyId": args.key_id, "algorithm": "Ed25519",
        "publicKeySHA256": fingerprint, "publicKeyHex": raw.hex(),
        "createdAt": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    }
    (out / f"{args.key_id}.json").write_text(json.dumps(record, indent=2) + "\n")
    del key, passphrase

    print(f"Key ID:      {args.key_id}")
    print(f"Fingerprint: {fingerprint}")
    print(f"Written:     {out}")
    print("Trust-store entry (review, then commit):")
    print(f'    "{args.key_id}": Data([' + ", ".join(f"0x{b:02x}" for b in raw) + "])")
    print("Back up the whole directory, and the passphrase separately, before first use.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
