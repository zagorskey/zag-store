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

mkdir -p "$OUT/headers"

cat > "$OUT/headers/zag_rppairing.h" <<'EOF'
#pragma once
#include <stdbool.h>
#include <stdint.h>

typedef void (*ZagRPPairingCallback)(int32_t code, const char *message);

char *zag_rppairing_core_version(void);
void zag_rppairing_string_free(char *value);
bool zag_rppairing_start(const char *host_name, const char *output_path, ZagRPPairingCallback callback);
bool zag_gate2_probe(const char *device_ip, const char *pairing_path, ZagRPPairingCallback callback);
bool zag_gate4_install(const char *device_ip, const char *pairing_path, const char *ipa_path, ZagRPPairingCallback callback);
bool zag_gate4_uninstall(const char *device_ip, const char *pairing_path, const char *bundle_id, ZagRPPairingCallback callback);
EOF

cat > "$OUT/headers/module.modulemap" <<'EOF'
module ZagRPPairingCore {
  header "zag_rppairing.h"
  export *
}
EOF

xcodebuild -create-xcframework \
  -library "$OUT/device/libzag_rppairing_core.a" -headers "$OUT/headers" \
  -library "$OUT/simulator/libzag_rppairing_core.a" -headers "$OUT/headers" \
  -output "$XCFRAMEWORK"

echo
echo "Built: $XCFRAMEWORK"
