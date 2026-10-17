#!/usr/bin/env python3
"""Compare Python RFC 8785 JCS against the checked-in Swift Foundation probe.

Requires scripts/requirements-release-signing.txt. No production keys used.
Run Swift probe and pass its output using --swift-output /path/to/log.
"""
import argparse
import json
import re
from pathlib import Path
import jcs

cases = [
    "ASCII release notes",
    "Обновяване на Заг Стор",
    "Café ☕ — 日本語",
    'Quotes " slash / backslash \\ tab \t newline \n',
    "Emoji 🔐🚀 and combining e\u0301",
]

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--swift-output", required=True, type=Path)
    args = parser.parse_args()
    observed = {}
    for line in args.swift_output.read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"CASE (\d+): ([0-9a-f]+)", line.strip())
        if match:
            observed[int(match.group(1))] = match.group(2)
    if set(observed) != set(range(len(cases))):
        parser.error("Expected exactly CASE 0 through CASE 4 from Swift probe")
    errors = 0
    for i, note in enumerate(cases):
        expected = jcs.canonicalize({"releaseNotes": note, "schema": 2}).hex()
        ok = observed[i] == expected
        print(f'{"PASS" if ok else "FAIL"}: CASE {i} Foundation vs JCS')
        if not ok:
            errors += 1
            print("  Foundation:", observed[i])
            print("  Python JCS:", expected)
    if errors:
        raise SystemExit(f"FAIL: {errors} canonicalization mismatches")
    print("SUCCESS: All five characterization fixtures match Python JCS")
    print("NOTE: This limited probe does not establish full RFC 8785 compliance.")

if __name__ == "__main__":
    main()
