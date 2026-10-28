#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

SOURCE_DIR="${1:-$HOME/Downloads}"
LIGHT="$SOURCE_DIR/ZagStore_ClearGlass_Light_OfficialAligned_1024.png"
DARK="$SOURCE_DIR/ZagStore_ClearGlass_Dark_OfficialAligned_1024.png"

for source in "$LIGHT" "$DARK"; do
    if [[ ! -f "$source" ]]; then
        echo "Missing: $source" >&2
        echo "Download both PNG files from the ChatGPT conversation into $SOURCE_DIR and retry." >&2
        exit 1
    fi
    [[ "$(sips -g pixelWidth "$source" | awk '/pixelWidth:/ {print $2}')" == 1024 ]]
    [[ "$(sips -g pixelHeight "$source" | awk '/pixelHeight:/ {print $2}')" == 1024 ]]
done

ASSETS="Feather/Resources/Assets.xcassets"
mkdir -p "$ASSETS/ZagClearGlass.appiconset" "$ASSETS/ZagClearGlassLight.imageset" "$ASSETS/ZagClearGlassDark.imageset"

cp "$LIGHT" "$ASSETS/ZagClearGlass.appiconset/ZagClearGlassLight.png"
cp "$DARK" "$ASSETS/ZagClearGlass.appiconset/ZagClearGlassDark.png"
cp "$LIGHT" "$ASSETS/ZagClearGlassLight.imageset/ZagClearGlassLight.png"
cp "$DARK" "$ASSETS/ZagClearGlassDark.imageset/ZagClearGlassDark.png"

cat > "$ASSETS/ZagClearGlass.appiconset/Contents.json" <<'JSON'
{
  "images": [
    { "filename": "ZagClearGlassLight.png", "idiom": "universal", "platform": "ios", "size": "1024x1024" },
    { "appearances": [{ "appearance": "luminosity", "value": "dark" }], "filename": "ZagClearGlassDark.png", "idiom": "universal", "platform": "ios", "size": "1024x1024" }
  ],
  "info": { "author": "xcode", "version": 1 }
}
JSON

cat > "$ASSETS/ZagClearGlassLight.imageset/Contents.json" <<'JSON'
{ "images": [{ "filename": "ZagClearGlassLight.png", "idiom": "universal" }], "info": { "author": "xcode", "version": 1 } }
JSON

cat > "$ASSETS/ZagClearGlassDark.imageset/Contents.json" <<'JSON'
{ "images": [{ "filename": "ZagClearGlassDark.png", "idiom": "universal" }], "info": { "author": "xcode", "version": 1 } }
JSON

echo "Installed Liquid Glass light/dark icons and preview assets."
echo "Review with git status --short, then run make iphoneos."
