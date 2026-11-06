#!/usr/bin/env python3 -I
"""Unpack a signed .shortcut (AEA1) using the public key from its own Apple
certificate chain, verify the signature with /usr/bin/aea, and print every
action with its full parameters. Also accepts an unsigned plist.

Usage: python3 -I inspect.py <file.shortcut> [--json]
"""
import json, os, plistlib, struct, subprocess, sys, tempfile

def load(path):
    data = open(path, "rb").read()
    if data[:4] != b"AEA1":
        return plistlib.loads(data), "unsigned"
    size = struct.unpack("<I", data[8:12])[0]
    chain = plistlib.loads(data[12:12 + size])["SigningCertificateChain"]
    with tempfile.TemporaryDirectory() as tmp:
        leaf = os.path.join(tmp, "leaf.der"); pem = os.path.join(tmp, "leaf.pem")
        open(leaf, "wb").write(chain[0])
        subject = subprocess.run(["openssl", "x509", "-inform", "der", "-in", leaf, "-noout", "-issuer"], capture_output=True, text=True, check=True).stdout.strip()
        key = subprocess.run(["openssl", "x509", "-inform", "der", "-in", leaf, "-pubkey", "-noout"], capture_output=True, check=True).stdout
        open(pem, "wb").write(key)
        aar = os.path.join(tmp, "payload.aar"); out = os.path.join(tmp, "out")
        subprocess.run(["aea", "decrypt", "-i", path, "-o", aar, "-sign-pub", pem], check=True)  # fails if the signature is invalid
        subprocess.run(["aa", "extract", "-i", aar, "-d", out], check=True)
        return plistlib.load(open(os.path.join(out, "Shortcut.wflow"), "rb")), f"signed, signature verified, {subject}"

def main():
    workflow, how = load(sys.argv[1])
    print(f"# {sys.argv[1]} ({how})")
    for key in sorted(k for k in workflow if k != "WFWorkflowActions"):
        print(f"{key} = {json.dumps(workflow[key], default=str)}")
    for n, action in enumerate(workflow["WFWorkflowActions"], 1):
        print(f"\n[{n}] {action['WFWorkflowActionIdentifier']}")
        print(json.dumps(action.get("WFWorkflowActionParameters", {}), indent=2, sort_keys=True, default=str))

if __name__ == "__main__":
    main()
