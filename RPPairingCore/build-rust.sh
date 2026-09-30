#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CRATE="$ROOT/rust-core"
OUT="$ROOT/build"
XCFRAMEWORK="$ROOT/ZagRPPairingCore.xcframework"

rustup target add aarch64-apple-ios aarch64-apple-ios-sim

cargo build --manifest-path "$CRATE/Cargo.toml" --release --target aarch64-apple-ios
cargo build --manifest-path "$CRATE/Cargo.toml" --release --target aarch64-apple-ios-sim

rm -rf "$OUT" "$XCFRAMEWORK"
mkdir -p "$OUT/device" "$OUT/simulator"

cp "$CRATE/target/aarch64-apple-ios/release/libzag_rppairing_core.a" "$OUT/device/"
cp "$CRATE/target/aarch64-apple-ios-sim/release/libzag_rppairing_core.a" "$OUT/simulator/"

cat > "$OUT/zag_rppairing.h" <<'EOF'
#pragma once
char *zag_rppairing_core_version(void);
void zag_rppairing_string_free(char *value);
EOF

xcodebuild -create-xcframework \
  -library "$OUT/device/libzag_rppairing_core.a" -headers "$OUT" \
  -library "$OUT/simulator/libzag_rppairing_core.a" -headers "$OUT" \
  -output "$XCFRAMEWORK"

echo
echo "Built: $XCFRAMEWORK"
