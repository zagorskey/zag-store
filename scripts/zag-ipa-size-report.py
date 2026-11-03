#!/usr/bin/env python3
"""Compare signed IPA component sizes without changing either archive."""
import argparse
import collections
import hashlib
from pathlib import Path
import zipfile


def inspect(path):
    groups = collections.defaultdict(lambda: [0, 0])
    with zipfile.ZipFile(path) as archive:
        bad = archive.testzip()
        if bad:
            raise ValueError(f"CRC verification failed: {bad}")
        for item in archive.infolist():
            if item.is_dir():
                continue
            name = item.filename
            if name.endswith("/Assets.car"):
                group = "Asset catalogue"
            elif name == "Payload/Feather.app/Feather":
                group = "Executable"
            elif "/Frameworks/" in name:
                group = "Embedded frameworks"
            elif name.endswith(".mp4"):
                group = "Video"
            else:
                group = "Other resources and signing"
            groups[group][0] += item.file_size
            groups[group][1] += item.compress_size
    size = path.stat().st_size
    overhead = size - sum(values[1] for values in groups.values())
    return size, hashlib.sha256(path.read_bytes()).hexdigest(), groups, overhead


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("optimised", type=Path)
    args = parser.parse_args()
    before, after = inspect(args.baseline), inspect(args.optimised)
    print("| Component | Baseline raw | Baseline ZIP | Optimised raw | Optimised ZIP |")
    print("|---|---:|---:|---:|---:|")
    for group in sorted(before[2].keys() | after[2].keys()):
        a, b = before[2].get(group, [0, 0]), after[2].get(group, [0, 0])
        print(f"| {group} | {a[0]:,} | {a[1]:,} | {b[0]:,} | {b[1]:,} |")
    print(f"\nZIP headers/metadata: {before[3]:,} → {after[3]:,} bytes.")
    print(f"\nIPA: {before[0]:,} → {after[0]:,} bytes.")
    saved = before[0] - after[0]
    print(f"Savings: {saved:,} bytes ({saved / 1048576:.4f} MiB; {100 * saved / before[0]:.4f}%).")
    print(f"\nBaseline SHA-256: `{before[1]}`")
    print(f"\nOptimised SHA-256: `{after[1]}`")
    print("\nBoth archives passed ZIP CRC verification.")


if __name__ == "__main__":
    main()
