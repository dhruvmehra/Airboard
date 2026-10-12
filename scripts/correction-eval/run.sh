#!/bin/bash
# Offline eval for EditDiff: did the user's edit teach a spelling fix?
# Synthetic correction traces only; no network, no app.
# Usage: scripts/correction-eval/run.sh [-v]   (-v lists every miss)
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=$(mktemp -d)
swiftc -parse-as-library \
  Airboard/SoundCode.swift Airboard/EditDiff.swift \
  scripts/correction-eval/EditDiffBaseline.swift scripts/correction-eval/main.swift \
  -o "$OUT/correction-eval"
"$OUT/correction-eval" scripts/correction-eval/traces.json "$@"
