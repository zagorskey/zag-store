#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
SOURCE_DIR="${1:-$HOME/Downloads}"
LIGHT="$SOURCE_DIR/ZagStore_Matrix_Light_1024.png"
DARK="$SOURCE_DIR/ZagStore_Matrix_Dark_1024.png"

for source in "$LIGHT" "$DARK"; do
    if [[ ! -f "$source" ]]; then
        echo "Missing: $source" >&2
        echo "Download the two separate Matrix PNG files to $SOURCE_DIR first." >&2
        exit 1
    fi
    width="$(sips -g pixelWidth "$source" | awk '/pixelWidth:/ {print $2}')"
    height="$(sips -g pixelHeight "$source" | awk '/pixelHeight:/ {print $2}')"
    if [[ "$width" != "1024" || "$height" != "1024" ]]; then
        echo "Expected 1024x1024: $source (got ${width}x${height})" >&2
        exit 1
    fi
done

ASSETS="Feather/Resources/Assets.xcassets"
mkdir -p "$ASSETS/ZagMatrix.appiconset" "$ASSETS/ZagMatrixLight.imageset" "$ASSETS/ZagMatrixDark.imageset"
cp "$LIGHT" "$ASSETS/ZagMatrix.appiconset/ZagMatrixLight.png"
cp "$DARK" "$ASSETS/ZagMatrix.appiconset/ZagMatrixDark.png"
cp "$LIGHT" "$ASSETS/ZagMatrixLight.imageset/ZagMatrixLight.png"
cp "$DARK" "$ASSETS/ZagMatrixDark.imageset/ZagMatrixDark.png"

cat > "$ASSETS/ZagMatrix.appiconset/Contents.json" <<'JSON'
{
  "images": [
    { "filename": "ZagMatrixLight.png", "idiom": "universal", "platform": "ios", "size": "1024x1024" },
    { "appearances": [{ "appearance": "luminosity", "value": "dark" }], "filename": "ZagMatrixDark.png", "idiom": "universal", "platform": "ios", "size": "1024x1024" }
  ],
  "info": { "author": "xcode", "version": 1 }
}
JSON
cat > "$ASSETS/ZagMatrixLight.imageset/Contents.json" <<'JSON'
{ "images": [{ "filename": "ZagMatrixLight.png", "idiom": "universal" }], "info": { "author": "xcode", "version": 1 } }
JSON
cat > "$ASSETS/ZagMatrixDark.imageset/Contents.json" <<'JSON'
{ "images": [{ "filename": "ZagMatrixDark.png", "idiom": "universal" }], "info": { "author": "xcode", "version": 1 } }
JSON

echo "Matrix icon assets installed (Light and Dark)."
echo "Gallery order: Official, Liquid Glass, Burning Wood, Matrix."
