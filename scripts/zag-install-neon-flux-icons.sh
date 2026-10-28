#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE_DIR="${1:-$HOME/Downloads}"
LIGHT="$SOURCE_DIR/ZagStore_NeonFlux_Light_1024.png"
DARK="$SOURCE_DIR/ZagStore_NeonFlux_Dark_1024.png"

for source in "$LIGHT" "$DARK"; do
    if [[ ! -f "$source" ]]; then
        echo "Missing icon file: $source" >&2
        exit 1
    fi
    width="$(sips -g pixelWidth "$source" | awk '/pixelWidth:/ {print $2}')"
    height="$(sips -g pixelHeight "$source" | awk '/pixelHeight:/ {print $2}')"
    if [[ "$width" != "1024" || "$height" != "1024" ]]; then
        echo "Expected 1024x1024 PNG: $source; got ${width}x${height}" >&2
        exit 1
    fi
done

ASSETS="Feather/Resources/Assets.xcassets"
mkdir -p "$ASSETS/ZagNeonFlux.appiconset" "$ASSETS/ZagNeonFluxLight.imageset" "$ASSETS/ZagNeonFluxDark.imageset"

cp "$LIGHT" "$ASSETS/ZagNeonFlux.appiconset/ZagNeonFluxLight.png"
cp "$DARK" "$ASSETS/ZagNeonFlux.appiconset/ZagNeonFluxDark.png"
cp "$LIGHT" "$ASSETS/ZagNeonFluxLight.imageset/ZagNeonFluxLight.png"
cp "$DARK" "$ASSETS/ZagNeonFluxDark.imageset/ZagNeonFluxDark.png"

cat > "$ASSETS/ZagNeonFlux.appiconset/Contents.json" <<'JSON'
{
  "images": [
    { "filename": "ZagNeonFluxLight.png", "idiom": "universal", "platform": "ios", "size": "1024x1024" },
    { "appearances": [{ "appearance": "luminosity", "value": "dark" }], "filename": "ZagNeonFluxDark.png", "idiom": "universal", "platform": "ios", "size": "1024x1024" }
  ],
  "info": { "author": "xcode", "version": 1 }
}
JSON

cat > "$ASSETS/ZagNeonFluxLight.imageset/Contents.json" <<'JSON'
{ "images": [{ "filename": "ZagNeonFluxLight.png", "idiom": "universal" }], "info": { "author": "xcode", "version": 1 } }
JSON

cat > "$ASSETS/ZagNeonFluxDark.imageset/Contents.json" <<'JSON'
{ "images": [{ "filename": "ZagNeonFluxDark.png", "idiom": "universal" }], "info": { "author": "xcode", "version": 1 } }
JSON

echo "Neon Flux icon assets installed."
echo "Gallery order: Official, Liquid Glass, Burning Wood, Matrix, Neon Flux."
