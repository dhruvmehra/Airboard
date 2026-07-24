# Design System v2 (Sleek Dark) Adoption + Guided Onboarding — Design

**Date:** 2026-07-24
**Status:** Approved

## Goal

Bring the shipping app up to the design system's approved **v2 Sleek Dark**
direction (`.claude/skills/airboard-design`, "Design direction v2"): dark-only
tokenized surfaces, blue-led actions, semantic accents, the tinted-badge
motif at v2 values — and replace the basic first-run setup window with the
DS's **guided onboarding flow** (reference implementation:
`ui_kits/airboard-app/onboarding.html`). Ships as part of the next release
(with mic selection et al.); the team receives it via auto-update.

## Scope

**In scope**
- `DesignSystem.swift` (new): the v2 tokens from `tokens/*.css` translated
  once into Swift constants — surfaces (`#0F0F11` window, `#161618` panel,
  `#1D1D20` control, HUD `rgba(24,24,28,.78)` + white@10% hairline), label
  alphas (92/55/28/10%), fills, tinted-badge colors (accent@16%), semantic
  accents (blue `#0A84FF` primary; red reserved for recording + logo),
  radii (3/8/10/12/16/full), spacing scale, and font helpers (system,
  SF Mono for values/keycaps, SF Pro Rounded for percentage readouts).
  All restyled views consume ONLY these constants.
- **Dark-only**: `NSApp.appearance = NSAppearance(named: .darkAqua)` at
  launch. The app renders dark regardless of the system setting.
- **Restyle of every existing surface** (layout and behavior unchanged;
  colors/typography/fills move to tokens; ui-kit screens are the visual
  reference): `AirboardPopover`, `CleanupSettingsView`, `HotkeySettingsView`,
  `PerformanceView`, `FeedbackView`, the download modal + floating indicator
  (`FloatingWindowManager`), and the switch style (DS Switch: green capsule =
  on; custom-drawn — never NSSwitch, per the non-activating-panel lesson).
  Blue-led CTAs; red never used for chrome.
- **Guided onboarding** (new SwiftUI flow, replaces the setup window's
  content): steps `01 Welcome → 02 The Gesture → 03 Microphone →
  04 Accessibility → 05 Your Hotkey → 06 Try It`, with the numbered step
  rail, at the reference's 920×640. **Skippable**: a quiet "Skip Setup"
  affordance (label-secondary, never a primary button) on every step;
  skipping marks setup complete and relies on the popover's permission
  status card for anything not granted.
- The **Try It** step drives the real dictation pipeline (hold ⌥, speak,
  text appears in an in-window text area) — not a simulation.
- Docs + changelog.

**Out of scope (explicitly deferred)**
- Light-mode variants (v2 is dark-only by decision).
- Any behavior/feature changes to the surfaces being restyled — this project
  changes pixels, not logic. (Exception: onboarding replaces the setup
  window's presentation; its permission logic is reused as-is.)
- Rewriting permission handling — `SetupWindowController`'s mic-request and
  accessibility-polling code is battle-tested and is reused behind the new
  UI.
- The DS's web/React components (`_ds_bundle.js`, Lucide) — the app is
  SwiftUI with SF Symbols; only tokens and layouts transfer.
- Marketing/README visuals.

## Decisions made during brainstorming

| Decision | Choice | Why |
|---|---|---|
| Scope | Full v2: all surfaces + onboarding | User chose the complete approved direction; onboarding is the team's first impression. |
| Appearance | Dark-only, forced | v2 is dark-only by design; single look to build and test; standard for menubar utilities. |
| Token encoding | One `DesignSystem.swift` mirroring `tokens/*.css` | Single source of truth in code; restyles reference constants, not hex literals; future tweaks are one-file. |
| Onboarding skippability | Skippable from every step, quiet affordance | User decision. Skip = `hasCompletedSetup = true`; popover's existing permission card covers ungrated permissions. |
| Permission logic | Reused from `SetupWindowController`, not rewritten | TCC flows are the most debugged code in the app (mic entitlement saga); only the presentation changes. |
| Controls in panels | Custom-drawn per DS components (Switch et al.) | Non-activating panels render system controls in inactive states (NSSwitch tint lesson). |
| Onboarding size | 920×640 per the reference | Matches the approved reference's proportions; one-time window, size is fine. |
| Web view embedding | Rejected | Non-native; the DS's identity IS native macOS. |

## Architecture

```
DesignSystem.swift            ← tokens (colors, fills, radii, spacing, fonts)
        ▲ consumed by
AirboardPopover / CleanupSettingsView / HotkeySettingsView /
PerformanceView / FeedbackView / FloatingWindowManager (indicator+modal)
        │ restyled only — layout/behavior identical
OnboardingFlow.swift (new)    ← 6 steps + rail + skip; 920×640 window
        │ presentation only
SetupWindowController         ← window management + permission logic reused;
                                shows OnboardingFlow instead of the old view;
                                completion/skip → hasCompletedSetup, onComplete()
```

### Onboarding step behaviors

1. **Welcome** — brand mark (real app icon asset), privacy-first headline
   ("All speech recognition runs locally on your Mac"), Continue.
2. **The Gesture** — explains hold-⌥-to-dictate with the keycap motif
   (SF Mono keycaps); Continue.
3. **Microphone** — reuses the existing `AVCaptureDevice.requestAccess` flow;
   state shown as a v2 StatusCard (pending → granted); auto-advances on
   grant, Continue enabled either way (deniable, fixable later).
4. **Accessibility** — reuses the existing open-System-Settings + polling
   flow; same StatusCard treatment; auto-advances on grant.
5. **Your Hotkey** — the existing hotkey option picker (OptionRow styling
   from the DS); defaults preserved.
6. **Try It** — a text area + live instruction; the user holds ⌥ and speaks;
   real pipeline inserts the transcription into the text area; a success
   state ("You're ready") completes setup.
- **Skip Setup** on every step (quiet, label-secondary): marks complete,
  closes, same post-setup wiring as finishing (hotkey monitoring starts).
- Shown only when `hasCompletedSetup` is false — existing users never see it.

### What "restyle" means per surface (uniform rules)

- Backgrounds → `surface-panel`/`surface-control`; windows opaque dark
  (no transparent chrome anywhere — the click-through lesson stands).
- Text → label alphas; values/metrics → SF Mono; percentages → SF Pro Rounded.
- Icon badges → 32px disc, accent@16% fill (v2 value; today's 10% goes away),
  vivid glyph.
- CTAs/selection/progress → `--sys-blue`; green only for success/on states;
  purple for AI/command; orange transcribing/warn; red ONLY recording.
- Hairlines → white@8–10%; inputs → `surface-control` with white@14% border.
- Popover keeps HUD blur (it's the one legitimately floating panel) with the
  white@10% hairline; settings WINDOWS are opaque `surface-panel`.

## Failure handling

Purely visual work — no new failure modes. Onboarding inherits the existing
permission flows' behavior (deny → continue allowed → popover status card
prompts later). The Try It step failing (e.g., model still downloading)
shows the same download-progress state the app already has, inside the step.

## Verification (manual, run by the user — this is a visual project)

1. Every surface, side by side with its ui-kit screen: popover, cleanup,
   hotkey, performance, feedback, download modal, floating indicator.
2. Dark-only: app renders identically with macOS in light mode.
3. Fresh-install onboarding (dev build: `defaults delete
   com.pype.airboard.dev hasCompletedSetup` + `tccutil reset` mic/AX):
   walk all six steps, grant both permissions, dictate in Try It, finish.
4. Skip path: fresh state → Skip on step 1 → app fully usable; popover shows
   the permission card until granted.
5. Existing-user path: normal launch shows NO onboarding.
6. Semantics spot-check: nothing red except recording state + logo; CTAs
   blue; switch green when on.
7. Regression: dictation, hands-free, command mode, mic picker, cleanup
   settings all behave exactly as before (pixels changed, behavior didn't).

## Risks

- **Breadth**: every visible surface changes at once; the per-surface visual
  pass (against ui-kit references) is the gate, and surfaces are restyled in
  separate commits so any one can be reverted alone.
- **Onboarding regressions in permission flows**: mitigated by reusing the
  existing logic verbatim behind new views; the fresh-install test (step 3)
  exercises the real TCC path.
- **Non-activating panel quirks**: all interactive controls in the popover
  are custom-drawn (existing GreenSwitchToggleStyle precedent; DS Switch
  spec).
- **Try It depends on the model being ready**: first-run downloads ~460MB;
  the step must handle "still downloading" gracefully (shows existing
  progress UI; user can Skip).
