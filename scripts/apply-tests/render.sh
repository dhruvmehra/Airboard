#!/bin/bash
# Renders devset.txt with TTS to WAV FILES (say -o, never played), transcribes
# them with a prebuilt Parakeet probe (scripts/name-eval/probe), and prints
# parakeet.tsv rows (id voice truth parakeet) to stdout.
#   PROBE=/path/to/probe scripts/apply-tests/render.sh <audio-dir> [ids-regex] >> parakeet.tsv
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
AUDIO="$1"; ONLY="${2:-.*}"
VOICES="${VOICES:-Rishi Aman Tara Samantha Daniel}"
mkdir -p "$AUDIO"
: > "$AUDIO/manifest.tsv"
grep -v '^#' "$HERE/devset.txt" | grep -E "^($ONLY)\|" | while IFS='|' read -r id text; do
  for v in $VOICES; do
    f="$AUDIO/$id-$v.wav"
    for _ in 1 2 3 4; do
      say -v "$v" -o "$f" --data-format=LEI16@16000 "$text"
      [ "$(wc -c < "$f")" -ge 16000 ] && break
    done
    printf '%s\t%s\t%s\t%s\n' "$(basename "$f")" "$id" "$v" "$text" >> "$AUDIO/manifest.tsv"
  done
done
cut -f1 "$AUDIO/manifest.tsv" | sed "s|^|$AUDIO/|" | xargs "$PROBE" > "$AUDIO/transcripts.tsv"
awk -F'\t' 'NR==FNR { t[$1]=$2; next } { printf "%s\t%s\t%s\t%s\n", $2, $3, $4, t[$1] }' \
  "$AUDIO/transcripts.tsv" "$AUDIO/manifest.tsv"
