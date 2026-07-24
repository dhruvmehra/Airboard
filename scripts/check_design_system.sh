#!/bin/bash
#
# Design-system adoption check: every styled view must consume DS.* tokens,
# never raw SwiftUI color literals. Run manually anytime; build_release.sh
# runs it as a release gate.
#
# Allowed exceptions:
#   - DesignSystem.swift (defines the tokens, so it holds the raw values)
#   - OnboardingFlow.swift Color(hex:) values (reference-mandated gradients
#     and tile glyph colors from the approved onboarding.html)
#   - Color.black / Color.white / Color.clear (shadows, scrims, knobs)
#
set -u
cd "$(dirname "$0")/.."
SRC="Airboard"
FAIL=0

section() { echo ""; echo "── $1"; }

section "1. Raw system-color literals outside DesignSystem.swift"
HITS=$(grep -rnE '(Color|\.foregroundColor\(|\.tint\()\.?(blue|green|purple|orange|red|teal|gray|yellow|pink|indigo|mint|cyan)\b' \
    "$SRC"/*.swift | grep -v "DesignSystem.swift" || true)
if [ -n "$HITS" ]; then
    echo "$HITS"
    echo "❌ Use DS.Palette/DS.Accent/DS.Tint tokens instead."
    FAIL=1
else
    echo "✅ none"
fi

section "2. Adaptive NSColor backgrounds in views (app is dark-only, tokenized)"
HITS=$(grep -rn "NSColor.windowBackgroundColor\|NSColor.textBackgroundColor\|NSColor.controlBackgroundColor" \
    "$SRC"/*.swift || true)
if [ -n "$HITS" ]; then
    echo "$HITS"
    echo "❌ Use DS.Surface tokens (or NSColor.dsSurface* for window chrome)."
    FAIL=1
else
    echo "✅ none"
fi

section "3. Raw hex colors outside the sanctioned files"
HITS=$(grep -rn "Color(hex:" "$SRC"/*.swift \
    | grep -v "DesignSystem.swift" | grep -v "OnboardingFlow.swift" || true)
if [ -n "$HITS" ]; then
    echo "$HITS"
    echo "❌ Add the value to DesignSystem.swift and reference the token."
    FAIL=1
else
    echo "✅ none"
fi

section "4. Brand mark is brand red (never blue, never a gradient)"
if grep -A4 'waveform.circle.fill' "$SRC/AirboardPopover.swift" | grep -q "DS.Brand.red"; then
    echo "✅ popover brand mark uses DS.Brand.red"
else
    echo "❌ The popover's waveform brand mark must use DS.Brand.red (#E5352B)."
    FAIL=1
fi

echo ""
if [ "$FAIL" -eq 1 ]; then
    echo "❌ Design-system check FAILED"
    exit 1
fi
echo "✅ Design-system check passed"
