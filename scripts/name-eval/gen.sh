#!/bin/bash
# Regenerates scripts/name-eval/corpus.json from real Parakeet output.
#   1. renders every sentences.txt line with each TTS voice to a WAV FILE
#      (say -o … — never played aloud) in a scratch dir (not committed);
#   2. transcribes them with the probe (scripts/name-eval/probe: FluidAudio
#      0.15.5, Parakeet TDT v3, the app's config);
#   3. build_corpus.py aligns each transcript to its truth and writes corpus.json.
# Usage: scripts/name-eval/gen.sh [audio-dir]
#   PROBE=/path/to/probe  use a prebuilt probe binary (default: swift build the package)
#   VOICES="Rishi Aman"   override the voice list
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
AUDIO="${1:-${TMPDIR:-/tmp}/name-eval-audio}"
VOICES="${VOICES:-Rishi Aman Tara Samantha Daniel}"
mkdir -p "$AUDIO"

if [ -z "${PROBE:-}" ]; then
  (cd "$HERE/probe" && swift build -c release >&2)
  PROBE="$HERE/probe/.build/release/probe"
fi

AVAILABLE=$(say -v '?' | awk '{print $1}')
USED=()
for v in $VOICES; do
  if ! grep -qx "$v" <<<"$AVAILABLE"; then echo "skip voice $v: not installed" >&2; continue; fi
  # Some installed voices render truncated audio (Tara, 2026-10-12: 0.2s for a
  # 2s sentence). Probe one sentence: < 1s of audio = broken voice, skip.
  say -v "$v" -o "$AUDIO/_check-$v.wav" --data-format=LEI16@16000 "This is a quick voice check sentence."
  bytes=$(wc -c < "$AUDIO/_check-$v.wav")
  if [ "$bytes" -lt 32000 ]; then echo "skip voice $v: renders truncated audio ($bytes bytes)" >&2; continue; fi
  USED+=("$v")
done
echo "voices: ${USED[*]}" >&2

: > "$AUDIO/manifest.tsv"
while IFS='|' read -r role id flags prev text; do
  [[ -z "$role" || "$role" == \#* ]] && continue
  spoken=$(sed -E 's/[{}]//g' <<<"$text")
  for v in "${USED[@]}"; do
    f="$id-$v.wav"
    # say occasionally renders a truncated file (~0.2s); retry those.
    for _ in 1 2 3 4; do
      say -v "$v" -o "$AUDIO/$f" --data-format=LEI16@16000 "$spoken"
      [ "$(wc -c < "$AUDIO/$f")" -ge 16000 ] && break
    done
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$f" "$role" "$id" "$v" "$flags" "$prev" "$text" >> "$AUDIO/manifest.tsv"
  done
done < "$HERE/sentences.txt"

cut -f1 "$AUDIO/manifest.tsv" | sed "s|^|$AUDIO/|" | xargs "$PROBE" > "$AUDIO/transcripts.tsv"
python3 -I "$HERE/build_corpus.py" "$AUDIO/manifest.tsv" "$AUDIO/transcripts.tsv" "$HERE/corpus.json"
