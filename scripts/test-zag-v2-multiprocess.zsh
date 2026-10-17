#!/bin/zsh
# Offline, multi-process anti-rollback regression. No app or signing changes.
set -e
set -o pipefail

cd "${0:A:h}/.."
WORKER="/tmp/zag-v2-sequence-worker"
RUNS="${1:-10}"
[[ "$RUNS" == <-> ]] && (( RUNS >= 1 && RUNS <= 100 )) || {
  echo "Usage: $0 [iterations 1..100]" >&2
  exit 2
}

echo "=== COMPILE INDEPENDENT PROCESS WORKER ==="
swiftc -warnings-as-errors \
  scripts/ZagMetadataV2SequenceStore.swift \
  scripts/ZagMetadataV2SequenceWorker.swift \
  -o "$WORKER"

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

for run in {1..$RUNS}; do
  STATE="$TEST_DIR/state-$run.json"
  mkdir -p "$TEST_DIR/iteration-$run"
  pids=()
  for sequence in {1..20}; do
    "$WORKER" "$STATE" beta "$sequence" \
      > "$TEST_DIR/iteration-$run/worker-$sequence.log" 2>&1 &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do
    wait "$pid"
  done
  python3 - "$STATE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    state = json.load(handle)
assert state["channels"]["beta"]["sequence"] == 20, state
print("PASS: Highest sequence is 20")
PY
  echo "PASS: Multi-process iteration $run/$RUNS"
done
echo "SUCCESS: Multi-process regression complete"
