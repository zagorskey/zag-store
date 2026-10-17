#!/usr/bin/env python3
"""Compare Swift Foundation's JSON bytes against Python RFC 8785 JCS fixtures.

This probe characterizes differences; a mismatch is expected for some number
formats and does not itself mean the staged v2 validator accepted unsafe input.
"""
import argparse
import re
from pathlib import Path
import jcs

cases = [
    {"releaseNotes": "ASCII release notes", "schema": 2},
    {"releaseNotes": "Обновяване на Заг Стор", "schema": 2},
    {"releaseNotes": "Café ☕ — 日本語", "schema": 2},
    {"releaseNotes": 'Quotes " slash / backslash \\ tab \t newline \n', "schema": 2},
    {"releaseNotes": "Emoji 🔐🚀 and combining e\u0301", "schema": 2},
    {"releaseNotes": "Control \b\f\u0000\u001f", "schema": 2},
    {"releaseNotes": "Line separators \u2028\u2029", "schema": 2},
    {"releaseNotes": "Supplementary 𝄞 and ZWJ 👩‍💻", "schema": 2},
    {"releaseNotes": "Latin Å vs A\u030A", "schema": 2},
    {"releaseNotes": "HTML <script>&", "schema": 2},
    {"releaseNotes": "Value", "schema": 2, "amount": 1.0},
    {"releaseNotes": "Value", "schema": 2, "amount": 1e-7},
    {"releaseNotes": "Value", "schema": 2, "amount": 1e21},
    {"releaseNotes": "Value", "schema": 2, "amount": -0.0},
    {"releaseNotes": "Value", "schema": 2, "amount": 333333333.3333333},
    {"releaseNotes": "Value", "schema": 2, "amount": 0.000001},
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
        parser.error(f"Expected CASE 0 through CASE {len(cases) - 1}")
    differences = 0
    for i, value in enumerate(cases):
        expected = jcs.canonicalize(value).hex()
        matches = observed[i] == expected
        print(f'{"MATCH" if matches else "DIFF"}: CASE {i} Foundation vs JCS')
        if not matches:
            differences += 1
            print("  Foundation:", observed[i])
            print("  Python JCS:", expected)
    print(f"RESULT: {len(cases) - differences}/{len(cases)} fixtures match")
    print("NOTE: Characterization only; no changes to production validation.")
if __name__ == "__main__":
    main()
