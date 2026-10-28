#!/usr/bin/env python3
"""Build a single appearance-aware iOS alternate app icon from the approved pair.

Run after extracting ZagStore_Firewood_Icon_Assets.zip at the repository root.
The Light/Dark selector in Settings is a preview only; iOS chooses the actual
Home Screen artwork from the asset catalog's luminosity appearances.
"""
import json
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "Feather/Resources/Assets.xcassets"
ICONSET = ASSETS / "ZagFirewood.appiconset"
SOURCES = {
    "light": ASSETS / "ZagFirewoodLight.imageset/icon.png",
    "dark": ASSETS / "ZagFirewoodDark.imageset/icon.png",
}
for appearance, source in SOURCES.items():
    if not source.is_file():
        raise SystemExit(f"Missing {appearance} image: {source}\nExtract the approved icon asset ZIP first.")
    # The source images are already 1024 x 1024. Do not resize or redraw them.
    with source.open("rb") as f:
        header = f.read(24)
    if header[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"Not a PNG: {source}")
    if int.from_bytes(header[16:20], "big") != 1024 or int.from_bytes(header[20:24], "big") != 1024:
        raise SystemExit(f"Icon must be 1024x1024: {source}")

ICONSET.mkdir(parents=True, exist_ok=True)
for appearance, source in SOURCES.items():
    shutil.copyfile(source, ICONSET / f"firewood-{appearance}.png")

catalog = {
    "images": [
        {
            "filename": "firewood-light.png",
            "idiom": "universal",
            "platform": "ios",
            "size": "1024x1024",
        },
        {
            "filename": "firewood-dark.png",
            "idiom": "universal",
            "platform": "ios",
            "size": "1024x1024",
            "appearances": [{"appearance": "luminosity", "value": "dark"}],
        },
    ],
    "info": {"author": "xcode", "version": 1},
}
(ICONSET / "Contents.json").write_text(json.dumps(catalog, indent=2) + "\n")
# The original icon already has native light/dark artwork. Expose both as
# preview images so the Settings selector reflects them too.
for appearance, filename in (("Light", "feather.png"), ("Dark", "feather_dark.png")):
    source = ASSETS / "AppIcon.appiconset" / filename
    if not source.is_file():
        raise SystemExit(f"Missing original icon asset: {source}")
    folder = ASSETS / f"ZagOriginal{appearance}.imageset"
    folder.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, folder / "icon.png")
    (folder / "Contents.json").write_text(
        json.dumps(
            {
                "images": [{"filename": "icon.png", "idiom": "universal"}],
                "info": {"author": "xcode", "version": 1},
            },
            indent=2,
        ) + "\n"
    )

print("Installed appearance-aware ZagFirewood app icon set.")
print("Light and dark share the same alternate icon name: ZagFirewood.")
