#!/bin/bash
# Release gate: prove pi + the bundled extension still work end-to-end.
# Fails the release if a pi update broke the extension API (pi has no
# stability guarantee) or if pi is missing on the publishing machine.
set -euo pipefail
cd "$(dirname "$0")/.."

PI="$(/bin/zsh -lc 'which pi' 2>/dev/null || true)"
if [[ -z "$PI" ]]; then
    echo "❌ assistant gate: pi is not installed (curl -fsSL https://pi.dev/install.sh | sh)"
    exit 1
fi

# File is shipped as .txt because Xcode won't copy .ts to Resources; copy to temp .ts
TMP_TS="$(mktemp -d)/assistant-tools.ts"
cp Airboard/assistant-tools.txt "$TMP_TS"

OUT="$(perl -e 'alarm 90; exec @ARGV' -- "$PI" -p --no-session --no-extensions --no-skills --no-context-files \
    --no-builtin-tools --offline -e "$TMP_TS" \
    --provider openrouter --model "openai/gpt-oss-120b:low" \
    --system-prompt "Use the calc tool for arithmetic. Reply with ONLY the number, nothing else." \
    "What is 2+2?" </dev/null 2>&1 | tail -1)"

if [[ "$OUT" != "4" && "$OUT" != "4." ]]; then
    echo "❌ assistant gate: expected 4, got: $OUT"
    exit 1
fi
echo "✅ assistant gate: calc round-trip OK ($OUT)"
