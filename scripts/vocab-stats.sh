#!/bin/bash
# Daily name-learning counters from the dev (default) or prod app.
# Usage: scripts/vocab-stats.sh [prod]
# The number to watch: "you fixed" falling while "Airboard fixed" rises.
set -euo pipefail
ID=com.pype.airboard.dev; [ "${1:-}" = prod ] && ID=com.pype.airboard
F="$HOME/Library/Application Support/$ID/vocab-stats.json"
[ -f "$F" ] || { echo "No stats yet ($F)"; exit 0; }
python3 - "$F" <<'PY'
import json, sys
days = json.load(open(sys.argv[1]))
print(f"{'day':<12}{'dictations':>11}{'Airboard fixed':>16}{'you fixed':>11}{'spelled':>9}{'kept':>6}{'undone':>8}{'auto share':>12}")
for k in sorted(days):
    d = days[k]; a, h = d.get('autoFixed', 0), d.get('handFixed', 0)
    share = f"{100*a/(a+h):.0f}%" if a + h else "—"
    print(f"{k:<12}{d.get('dictations',0):>11}{a:>16}{h:>11}{d.get('spelled',0):>9}{d.get('cardsKept',0):>6}{d.get('cardsUndone',0):>8}{share:>12}")
PY
