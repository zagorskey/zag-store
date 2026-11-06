#!/usr/bin/env bash
# Resize only Settings > App Icon previews to 288px (@3x for 96pt).
# Reads real image filenames from each imageset Contents.json; supports 512px
# and 1024px originals. Never modifies *.appiconset home-screen artwork.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
python3 - <<'PY'
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

root = Path("Feather/Resources/Assets.xcassets")
names = [
    "ZagOriginalLight", "ZagOriginalDark",
    "ZagClearGlassLight", "ZagClearGlassDark",
    "ZagFirewoodLight", "ZagFirewoodDark",
    "ZagMatrixLight", "ZagMatrixDark",
    "ZagMoneyLight", "ZagMoneyDark",
    "ZagGBPLight", "ZagGBPDark",
    "ZagNeonFluxLight", "ZagNeonFluxDark",
]
sources = []
for name in names:
    folder = root / f"{name}.imageset"
    manifest = folder / "Contents.json"
    if not manifest.is_file():
        raise RuntimeError(f"Missing manifest: {manifest}")
    entries = json.loads(manifest.read_text()).get("images", [])
    filenames = [x["filename"] for x in entries if x.get("filename")]
    if len(filenames) != 1:
        raise RuntimeError(f"Expected one preview image in {manifest}")
    path = folder / filenames[0]
    if not path.is_file():
        raise RuntimeError(f"Missing preview: {path}")
    info = subprocess.run(
        ["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)],
        check=True, capture_output=True, text=True,
    ).stdout
    width = int(re.search(r"pixelWidth:\s*(\d+)", info).group(1))
    height = int(re.search(r"pixelHeight:\s*(\d+)", info).group(1))
    if width != height or width < 288:
        raise RuntimeError(f"Unexpected dimensions: {name} {width}x{height}")
    sources.append((name, path, width))

backup = Path(tempfile.mkdtemp(prefix="zag-preview-originals-"))
stage = Path(tempfile.mkdtemp(prefix="zag-preview-resized-"))
print("Original preview backup:", backup)
for name, path, width in sources:
    shutil.copy2(path, backup / f"{name}.png")
    target = stage / f"{name}.png"
    if width == 288:
        shutil.copy2(path, target)
    else:
        subprocess.run(
            ["sips", "-s", "format", "png", "-z", "288", "288",
             str(path), "--out", str(target)],
            check=True, stdout=subprocess.DEVNULL,
        )
    info = subprocess.run(
        ["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(target)],
        check=True, capture_output=True, text=True,
    ).stdout
    if "pixelWidth: 288" not in info or "pixelHeight: 288" not in info:
        raise RuntimeError(f"Invalid resized output: {name}")

before = sum(path.stat().st_size for _, path, _ in sources)
for name, path, width in sources:
    shutil.copy2(stage / f"{name}.png", path)
    print(f"{name}: {width}x{width} -> 288x288")
after = sum(path.stat().st_size for _, path, _ in sources)
print(f"Source PNG savings: {(before - after) / 1048576:.2f} MiB")
print("Home Screen .appiconset artwork unchanged.")
print("Backup:", backup)
PY
