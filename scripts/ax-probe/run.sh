#!/bin/bash
# Accessibility exposure probe (E3). Prints only booleans/roles/counts/lengths.
# Usage: scripts/ax-probe/run.sh [--enhanced] [--keep] [--app <name-substring>]
# Requires the launching terminal to have Accessibility permission.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=$(mktemp -d)
swiftc -O scripts/ax-probe/main.swift -o "$OUT/ax-probe"
"$OUT/ax-probe" "$@"
