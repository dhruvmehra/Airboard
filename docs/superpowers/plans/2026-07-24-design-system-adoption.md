# Design System v2 Adoption + Guided Onboarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restyle every app surface to the design system's approved v2 "Sleek Dark" tokens and replace the first-run setup window with the DS's six-step guided onboarding flow.

**Architecture:** A new `DesignSystem.swift` translates `tokens/*.css` into Swift constants; the app forces dark appearance at launch; each existing surface is restyled in its own commit (pixels change, behavior doesn't); a new `OnboardingFlow.swift` (SwiftUI, 920×640, step rail, skippable) replaces `SetupWindowController`'s AppKit content while reusing its battle-tested permission logic.

**Tech Stack:** SwiftUI + AppKit hosting (existing patterns), no new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-24-design-system-adoption-design.md`
**DS reference:** `.claude/skills/airboard-design/` — `tokens/*.css` (values), `readme.md` (v2 direction), `ui_kits/airboard-app/` (visual references: `screens.jsx` for existing surfaces, `onboarding.html` for onboarding).

## Global Constraints

- **Dark-only.** `NSApp.appearance = NSAppearance(named: .darkAqua)` is set at launch (Task 1). No light variants anywhere.
- **Tokens only.** Restyled views consume `DS.*` constants exclusively — after a restyle task, the file contains no raw hex colors and no `Color.<system>.opacity(...)` tint literals (system colors *via* `DS.Palette`/`DS.Accent`/`DS.Tint` are the replacement).
- **Red is reserved** for the recording state and the logo. Never for chrome, buttons, errors-as-decoration, or icons. CTAs/selection/progress are `DS.Accent.primary` (blue #0A84FF). Green only for success/on states. Purple = AI/command. Orange = transcribing/warn.
- **No transparent window chrome.** Settings/onboarding windows are opaque (`NSColor.dsSurfaceWindow` / DS surface fills). Only the popover and floating indicator keep HUD blur — they are legitimately floating panels. (Transparent chrome caused the Sonoma click-through bug.)
- **No NSSwitch / no system-tinted controls in the non-activating popover panel** — controls there are custom-drawn (existing `GreenSwitchToggleStyle` precedent).
- **Layout and behavior unchanged** on restyled surfaces. Restyle = colors, typography, fills, borders, radii move to tokens. Do not move, add, or remove controls; do not rename user-facing copy. (Exception: onboarding replaces the setup window's presentation, Task 6.)
- **Permission logic reused, not rewritten.** `AVCaptureDevice` request flow, `AXIsProcessTrusted` polling, and System Settings deep links stay in `SetupWindowController` exactly as they are today; onboarding calls them.
- **Signing discipline:** all builds in this plan are Debug (`com.pype.airboard.dev`, Apple Development cert). Never build/launch the prod bundle id from this plan.
- **Build gate for every task:** `cd /Users/dhruvmehra/Desktop/proj/Airboard/Airboard && xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug build 2>&1 | tail -3` must end `** BUILD SUCCEEDED **`. There is no XCTest target; verification is build + the user's manual visual pass (final section).
- New `.swift` files under `Airboard/Airboard/` are picked up automatically (the project uses Xcode file-system-synchronized groups) — do NOT edit `project.pbxproj`.

### Canonical value→token mapping (applies to every restyle task)

| Current pattern | Replace with |
|---|---|
| `Color.blue.opacity(0.1)` / `(0.15)` badge fills | `DS.Tint.blue` |
| `Color.purple.opacity(0.1)` / `(0.15)` badge fills | `DS.Tint.purple` |
| `Color.orange.opacity(0.1)` / `(0.15)` badge fills | `DS.Tint.orange` |
| `Color.green.opacity(0.15)` badge fills | `DS.Tint.green` |
| `Color.blue.opacity(0.06–0.09)` card washes | `DS.Tint.cardBlue` |
| `Color.green.opacity(0.06)` card washes | `DS.Tint.cardGreen` |
| `Color.orange.opacity(0.08)` card washes | `DS.Tint.cardOrange` |
| `Color.blue` (glyphs, CTAs, selection, progress) | `DS.Accent.primary` |
| `Color.green` (success/on) | `DS.Accent.success` |
| `Color.orange` (transcribing/warn) | `DS.Accent.transcribing` / `DS.Accent.warning` |
| `Color.purple` (AI/command) | `DS.Accent.command` |
| red used for recording state | `DS.Accent.recording` |
| `.foregroundColor(.primary)` / `.foregroundStyle(.primary)` | `DS.Label.primary` |
| `.secondary` text | `DS.Label.secondary` |
| `.secondary.opacity(0.4–0.6)` / tertiary text | `DS.Label.tertiary` |
| `Color.gray.opacity(0.05–0.08)` panel/card fills | `DS.Fill.quaternary` |
| `Color.gray.opacity(0.15)` / `Color.primary.opacity(0.2)` tracks | `DS.Fill.track` |
| `Color.primary.opacity(0.05)` hover fills | `DS.Fill.hover` |
| `Color.gray.opacity(0.2)` / `Color.white.opacity(0.1)` strokes | `DS.Border.hairline` |
| input-field strokes | `DS.Border.control` |
| selected-option strokes (`Color.blue.opacity(0.3)`) | `DS.Border.selected` |
| `Color(NSColor.windowBackgroundColor)` view backgrounds | `DS.Surface.panel` |
| `Color(NSColor.textBackgroundColor)` input backgrounds | `DS.Surface.control` |
| numeric values / metrics / keycap glyph labels | `DS.Typo.mono(size, weight)` |
| percentage readouts | `DS.Typo.rounded(size, weight)` |

Corner radii: keep each view's existing radius but express it via `DS.Radius.*` when it matches the set {3, 5, 8, 10, 12, 16}; leave non-matching radii (e.g. a circle) as-is.

---

### Task 1: DesignSystem.swift token file + forced dark appearance

**Files:**
- Create: `Airboard/Airboard/DesignSystem.swift`
- Modify: `Airboard/Airboard/AirboardApp.swift` (top of `applicationDidFinishLaunching`)

**Interfaces:**
- Consumes: nothing (first task).
- Produces: the `DS` namespace every later task uses — `DS.Surface.{window,panel,control,hud,hudBorder}` (Color), `DS.Label.{primary,secondary,tertiary,quaternary,onAccent}`, `DS.Fill.{hover,quaternary,tertiary,secondary,track}`, `DS.Palette.{red,orange,green,cyan,blue,indigo,purple}`, `DS.Accent.{primary,recording,transcribing,command,download,success,warning}`, `DS.Tint.{red,orange,green,blue,purple,cardOrange,cardGreen,cardBlue}`, `DS.Border.{hairline,control,selected}`, `DS.Radius.{r3,r5,r8,r10,r12,r16,full}` (CGFloat), `DS.Badge.{size,glyph}` (CGFloat), `DS.Typo.{ui,mono,rounded}(_:_:) -> Font`, `Color(hex: UInt32)`, `NSColor.dsSurfaceWindow`, `NSColor.dsSurfacePanel`.

- [ ] **Step 1: Create the token file**

Write `Airboard/Airboard/DesignSystem.swift` exactly:

```swift
//
//  DesignSystem.swift
//
//  Airboard design system v2 "Sleek Dark" tokens, translated once from
//  .claude/skills/airboard-design/tokens/*.css. Styled views consume these
//  constants — never raw hex or ad-hoc Color.x.opacity() literals. The app
//  is dark-only (forced .darkAqua at launch); there are no light variants
//  by design.
//

import SwiftUI

enum DS {

    // MARK: Surfaces
    enum Surface {
        static let window  = Color(hex: 0x0F0F11)
        static let panel   = Color(hex: 0x161618)
        static let control = Color(hex: 0x1D1D20)
        static let hud       = Color(.sRGB, red: 24/255, green: 24/255, blue: 28/255, opacity: 0.78)
        static let hudBorder = Color.white.opacity(0.10)
    }

    // MARK: Labels
    enum Label {
        static let primary    = Color.white.opacity(0.92)
        static let secondary  = Color.white.opacity(0.55)
        static let tertiary   = Color.white.opacity(0.28)
        static let quaternary = Color.white.opacity(0.10)
        static let onAccent   = Color.white
    }

    // MARK: Fills
    enum Fill {
        static let hover      = Color.white.opacity(0.05)
        static let quaternary = Color.white.opacity(0.06)
        static let tertiary   = Color.white.opacity(0.08)
        static let secondary  = Color.white.opacity(0.12)
        static let track      = Color.white.opacity(0.14)
    }

    // MARK: Apple system palette (dark-appearance vivid values)
    enum Palette {
        static let red    = Color(hex: 0xFF453A)
        static let orange = Color(hex: 0xFF9F0A)
        static let green  = Color(hex: 0x30D158)
        static let cyan   = Color(hex: 0x64D2FF)
        static let blue   = Color(hex: 0x0A84FF)
        static let indigo = Color(hex: 0x5E5CE6)
        static let purple = Color(hex: 0xBF5AF2)
    }

    // MARK: Semantic accents
    enum Accent {
        static let primary      = Palette.blue    // every default CTA + selection
        static let recording    = Palette.red     // the ONLY UI use of red
        static let transcribing = Palette.orange
        static let command      = Palette.purple
        static let download     = Palette.blue
        static let success      = Palette.green
        static let warning      = Palette.orange
    }

    // MARK: Tinted badges (accent @16% behind a vivid glyph)
    enum Tint {
        static let red    = Palette.red.opacity(0.16)
        static let orange = Palette.orange.opacity(0.16)
        static let green  = Palette.green.opacity(0.16)
        static let blue   = Palette.blue.opacity(0.16)
        static let purple = Palette.purple.opacity(0.16)
        static let cardOrange = Palette.orange.opacity(0.10)
        static let cardGreen  = Palette.green.opacity(0.10)
        static let cardBlue   = Palette.blue.opacity(0.09)
    }

    // MARK: Borders
    enum Border {
        static let hairline = Color.white.opacity(0.08)
        static let control  = Color.white.opacity(0.14)
        static let selected = Palette.blue.opacity(0.55)
    }

    // MARK: Spacing scale
    enum Space {
        static let s2: CGFloat = 2
        static let s4: CGFloat = 4
        static let s6: CGFloat = 6
        static let s8: CGFloat = 8
        static let s10: CGFloat = 10
        static let s12: CGFloat = 12
        static let s16: CGFloat = 16
        static let s20: CGFloat = 20
        static let s24: CGFloat = 24
        static let s32: CGFloat = 32
    }

    // MARK: Radii
    enum Radius {
        static let r3: CGFloat = 3
        static let r5: CGFloat = 5
        static let r8: CGFloat = 8
        static let r10: CGFloat = 10
        static let r12: CGFloat = 12
        static let r16: CGFloat = 16
        static let full: CGFloat = 999
    }

    // MARK: Badge geometry
    enum Badge {
        static let size: CGFloat = 32
        static let glyph: CGFloat = 14
    }

    // MARK: Typography
    enum Typo {
        static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight)
        }
        static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .monospaced)
        }
        static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .rounded)
        }
    }
}

extension Color {
    /// 0xRRGGBB initializer for DS token values.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension NSColor {
    /// AppKit mirrors for window chrome (NSWindow.backgroundColor).
    static let dsSurfaceWindow = NSColor(srgbRed: 0x0F/255, green: 0x0F/255, blue: 0x11/255, alpha: 1)
    static let dsSurfacePanel  = NSColor(srgbRed: 0x16/255, green: 0x16/255, blue: 0x18/255, alpha: 1)
}
```

- [ ] **Step 2: Force dark appearance at launch**

In `Airboard/Airboard/AirboardApp.swift`, inside `applicationDidFinishLaunching`, insert immediately after `print("🚀 Airboard launched")`:

```swift
        // Design system v2 is dark-only: the app renders dark regardless of
        // the system appearance setting.
        NSApp.appearance = NSAppearance(named: .darkAqua)
```

- [ ] **Step 3: Build**

Run: `cd /Users/dhruvmehra/Desktop/proj/Airboard/Airboard && xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Airboard/Airboard/DesignSystem.swift Airboard/Airboard/AirboardApp.swift
git commit -m "feat: add design-system v2 tokens and force dark-only appearance"
```

---

### Task 2: Restyle the menubar popover (AirboardPopover.swift)

**Files:**
- Modify: `Airboard/Airboard/AirboardPopover.swift`
- Visual reference: `.claude/skills/airboard-design/ui_kits/airboard-app/screens.jsx` (popover screen) and `readme.md` ("Design direction v2")

**Interfaces:**
- Consumes: the `DS` namespace from Task 1.
- Produces: nothing new — same views, token colors.

- [ ] **Step 1: Read the current file and the DS references**

Read `Airboard/Airboard/AirboardPopover.swift` in full, plus the popover section of `screens.jsx` and `readme.md`'s v2 direction. The popover KEEPS its HUD blur (`VisualEffectBlur(material: .hudWindow, ...)`) — it is the one legitimately floating panel.

- [ ] **Step 2: Apply the canonical mapping across the file**

Apply the Global Constraints mapping table to every color literal. Popover-specific requirements on top of the table:

1. **Panel chrome** (currently around lines 338–356): keep the `VisualEffectBlur`, but layer the DS HUD wash and hairline. Replace the existing background/overlay/shadow block with:

```swift
        .background(
            ZStack {
                VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                RoundedRectangle(cornerRadius: DS.Radius.r16, style: .continuous)
                    .fill(DS.Surface.hud)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.r16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.r16, style: .continuous)
                .strokeBorder(DS.Surface.hudBorder, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.55), radius: 22, x: 0, y: 16)
```

(Keep the same corner radius the view uses today if it isn't 16 — check before replacing; the DS popover/panel radius is 16.)

2. **Icon badges** (mic blue, AI-cleanup purple, warning orange, success green): 32pt discs at `DS.Tint.<color>` fill with vivid glyph in `DS.Palette.<color>` / `DS.Accent.*`, glyph at 14pt (`DS.Badge.size` / `DS.Badge.glyph`). Today's `opacity(0.1)` fills all become the 16% tints.
3. **`GreenSwitchToggleStyle`** stays custom-drawn. Retoken it: on-fill `DS.Accent.success`, off-fill `DS.Fill.track`, knob stays white with its small shadow.
4. **Text**: title `DS.Label.primary`; subtitles/secondary `DS.Label.secondary`; disabled/hints `DS.Label.tertiary`.
5. **Recording-related accents only** may use `DS.Accent.recording`. Everything else red-free.
6. Do NOT touch logic: bindings, menus, `onChange` handlers, `micManager.refreshDevices()`, the open-cleanup-settings flow all stay byte-identical.

- [ ] **Step 3: Verify no raw tints remain**

Run: `grep -nE "Color\.(blue|green|purple|orange|red|gray|teal)\b|opacity\(0\.(0[5-9]|1[05])\)|NSColor\.windowBackgroundColor" Airboard/Airboard/AirboardPopover.swift`
Expected: no matches (or only matches inside `VisualEffectBlur` plumbing / the shadow line above).

- [ ] **Step 4: Build**

Run: `cd /Users/dhruvmehra/Desktop/proj/Airboard/Airboard && xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Airboard/Airboard/AirboardPopover.swift
git commit -m "style: restyle menubar popover to DS v2 tokens"
```

---

### Task 3: Restyle the Cleanup and Hotkey settings windows

**Files:**
- Modify: `Airboard/Airboard/CleanupSettingsView.swift`
- Modify: `Airboard/Airboard/HotkeySettingsView.swift`
- Visual reference: `.claude/skills/airboard-design/ui_kits/airboard-app/screens.jsx` (cleanup + hotkey screens)

**Interfaces:**
- Consumes: `DS` from Task 1.
- Produces: nothing new.

- [ ] **Step 1: Restyle CleanupSettingsView.swift**

Apply the canonical mapping. Specific requirements:
- Root background: add `.background(DS.Surface.panel)` on the outermost container (the window chrome stays standard opaque — do NOT touch `FloatingWindowManager`'s window creation in this task).
- AI badge: `DS.Tint.purple` fill, glyph `DS.Accent.command`, 32pt disc.
- Text fields: background `DS.Surface.control`, stroke `DS.Border.control`, radius `DS.Radius.r8`.
- Primary buttons (Save/Test): `DS.Accent.primary` fill, `DS.Label.onAccent` text, radius `DS.Radius.r8`.
- Success/"connected" feedback: `DS.Accent.success`. Errors are plain `DS.Label.secondary` text — NOT red.
- Labels per the table.

- [ ] **Step 2: Restyle HotkeySettingsView.swift**

Apply the canonical mapping. Specific requirements:
- Replace `.background(Color(NSColor.windowBackgroundColor))` with `.background(DS.Surface.panel)`.
- Option rows: selected = `DS.Tint.blue` fill + `DS.Border.selected` stroke + radio glyph `DS.Accent.primary`; hover = `DS.Fill.hover`; radius `DS.Radius.r10`.
- Unselected radio glyph: `DS.Label.tertiary`.
- Header/close button: `DS.Label.secondary` / `DS.Label.tertiary` per the table.

- [ ] **Step 3: Verify and build**

Run: `grep -nE "Color\.(blue|gray)\b|NSColor\.windowBackgroundColor|opacity\(0\.(0[45]|1)\)" Airboard/Airboard/CleanupSettingsView.swift Airboard/Airboard/HotkeySettingsView.swift`
Expected: no matches.

Run: `cd /Users/dhruvmehra/Desktop/proj/Airboard/Airboard && xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit (one per surface)**

```bash
git add Airboard/Airboard/CleanupSettingsView.swift
git commit -m "style: restyle AI Cleanup settings to DS v2 tokens"
git add Airboard/Airboard/HotkeySettingsView.swift
git commit -m "style: restyle Hotkey settings to DS v2 tokens"
```

---

### Task 4: Restyle Performance and Feedback windows

**Files:**
- Modify: `Airboard/Airboard/PerformanceView.swift`
- Modify: `Airboard/Airboard/FeedbackView.swift`
- Visual reference: `.claude/skills/airboard-design/ui_kits/airboard-app/screens.jsx`

**Interfaces:**
- Consumes: `DS` from Task 1.
- Produces: nothing new.

- [ ] **Step 1: Restyle PerformanceView.swift**

Apply the canonical mapping. Specific requirements:
- `.background(Color(NSColor.windowBackgroundColor))` → `.background(DS.Surface.panel)`.
- Metric cards (`Color.gray.opacity(0.08)` / `(0.05)`) → `DS.Fill.quaternary`; the `(0.15)` track → `DS.Fill.track`.
- The orange wash card (`Color.orange.opacity(0.08)`) → `DS.Tint.cardOrange`; the blue one (`Color.blue.opacity(0.08)`) → `DS.Tint.cardBlue`.
- **All numeric metric values → `DS.Typo.mono(...)` at their current sizes; percentage readouts → `DS.Typo.rounded(...)`** (this is the DS's signature typographic move for this screen).
- Progress fills → `DS.Accent.primary`, radius `DS.Radius.r3`.

- [ ] **Step 2: Restyle FeedbackView.swift**

Apply the canonical mapping. Specific requirements:
- Root background `DS.Surface.panel`.
- Transcript/context boxes: `Color(NSColor.textBackgroundColor)` → `DS.Surface.control`; `Color.gray.opacity(0.2)` strokes → `DS.Border.hairline`; `Color.gray.opacity(0.08)` fills → `DS.Fill.quaternary`.
- Send button: `DS.Accent.primary` / `DS.Label.onAccent`.
- Labels per the table.

- [ ] **Step 3: Verify and build**

Run: `grep -nE "Color\.(blue|gray|orange)\b|NSColor\.(windowBackgroundColor|textBackgroundColor)" Airboard/Airboard/PerformanceView.swift Airboard/Airboard/FeedbackView.swift`
Expected: no matches.

Run: `cd /Users/dhruvmehra/Desktop/proj/Airboard/Airboard && xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit (one per surface)**

```bash
git add Airboard/Airboard/PerformanceView.swift
git commit -m "style: restyle Performance window to DS v2 tokens"
git add Airboard/Airboard/FeedbackView.swift
git commit -m "style: restyle Feedback window to DS v2 tokens"
```

---

### Task 5: Restyle the floating indicator and download modal (FloatingWindowManager.swift)

**Files:**
- Modify: `Airboard/Airboard/FloatingWindowManager.swift`
- Visual reference: `.claude/skills/airboard-design/ui_kits/airboard-app/screens.jsx` (indicator + download modal screens)

**Interfaces:**
- Consumes: `DS` from Task 1.
- Produces: nothing new.

- [ ] **Step 1: Restyle the floating indicator views**

Apply the canonical mapping to the SwiftUI views in this file (roughly lines 570–860). Specific requirements:
- The indicator keeps its blur (`.ultraThinMaterial` / `VisualEffectView(material: .hudWindow, ...)`) — it is a floating HUD. Add the `DS.Surface.hud` wash + `DS.Surface.hudBorder` hairline over/around the blur, mirroring the popover treatment from Task 2.
- State accent colors: recording → `DS.Accent.recording`; transcribing → `DS.Accent.transcribing`; command → `DS.Accent.command`; download/progress → `DS.Accent.download`; idle glyph → `DS.Label.tertiary`.
- The blue→purple gradient on the download modal icon → a `DS.Palette.blue`→`DS.Palette.cyan` gradient (the DS's `--gradient-brand`); progress bar fill `DS.Accent.primary` on `DS.Fill.track`, radius `DS.Radius.r3`.
- Download modal panel: keep its window as-is, set the SwiftUI panel background to `DS.Surface.panel` with `DS.Border.hairline` stroke, radius `DS.Radius.r16`.
- Do NOT touch: window creation/level/collection behavior, `showCleanupSettingsWindow` / `showHotkeySettingsWindow` / `showPerformanceWindow` plumbing, popover event monitors — pixels only.

- [ ] **Step 2: Verify and build**

Run: `grep -nE "Color\.(blue|purple|white)\b.*opacity|Color\.black\.opacity\(0\.0" Airboard/Airboard/FloatingWindowManager.swift`
Expected: no matches in the view structs (window-plumbing matches are acceptable — list any you left and why in the report).

Run: `cd /Users/dhruvmehra/Desktop/proj/Airboard/Airboard && xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Airboard/Airboard/FloatingWindowManager.swift
git commit -m "style: restyle floating indicator and download modal to DS v2 tokens"
```

---

### Task 6: Guided onboarding flow

**Files:**
- Create: `Airboard/Airboard/OnboardingFlow.swift`
- Modify: `Airboard/Airboard/SetupWindowController.swift` (full rewrite shown below)
- Modify: `Airboard/Airboard/TranscriptionCoordinator.swift:77-95` (`setupObservers` + two new published mirrors)
- Visual reference: `.claude/skills/airboard-design/ui_kits/airboard-app/onboarding.html` — THE approved look; read it before writing SwiftUI. Note: the reference combines mic+accessibility into one "Permissions" step; the approved spec splits them into two rail steps — the spec governs the step list, the reference governs the visual treatment (rail, keycaps, chips, typography).

**Interfaces:**
- Consumes: `DS` from Task 1; `SetupWindowController.shared.{isMicrophoneGranted,isAccessibilityGranted}` (existing); `HotkeyManager.primaryHotkey` / `HotkeyOption` (existing: `.keyCode: UInt16`, `.modifierFlag: NSEvent.ModifierFlags`, `.displayName: String`); `TranscriptionCoordinator.shared.{startRecording(),stopRecording(mode:),$lastTranscribedText,$isRecording,$isTranscribing}` (existing).
- Produces: `OnboardingFlow(initialStep:onFinish:)` SwiftUI view with `OnboardingFlow.Step` enum (`.welcome,.gesture,.microphone,.accessibility,.hotkey,.tryIt`); `SetupWindowController.requestMicrophoneAccess()` and `.openAccessibilitySettings()` (now internal); `TranscriptionCoordinator.{isModelReady,modelDownloadProgress}` published mirrors.

- [ ] **Step 1: Add model-readiness mirrors to TranscriptionCoordinator**

In `TranscriptionCoordinator.swift`, add below the other `@Published` properties (near line 35):

```swift
    // Model readiness mirrors for onboarding's Try It step (the service
    // itself is private to the coordinator).
    @Published private(set) var isModelReady = false
    @Published private(set) var modelDownloadProgress: Double = 0
```

Replace the two sinks in `setupObservers()` (keeping their existing side effects byte-identical):

```swift
    private func setupObservers() {
        // Transcription service download progress
        transcriptionService.$downloadProgress
            .sink { [weak self] progress in
                self?.modelDownloadProgress = progress
                FloatingWindowManager.shared.showDownloadProgress(progress: progress)
            }
            .store(in: &cancellables)

        // When the model becomes fully ready (downloaded + warmed up), clear the
        // download state and pulse the floating icon so the user knows it's usable.
        transcriptionService.$isModelReady
            .removeDuplicates()
            .sink { [weak self] ready in
                self?.isModelReady = ready
                guard ready else { return }
                FloatingWindowManager.shared.hideFloatingIndicator()
                NotificationCenter.default.post(name: .pulseFloatingIcon, object: nil)
            }
            .store(in: &cancellables)
    }
```

- [ ] **Step 2: Create OnboardingFlow.swift**

Write `Airboard/Airboard/OnboardingFlow.swift`. The code below is the complete structure and behavior contract; match the reference's copy verbatim (it is quoted here) and its visual treatment (consult `onboarding.html` for proportions while building):

```swift
//
//  OnboardingFlow.swift
//
//  Guided first-run onboarding — design system v2 "Sleek Dark".
//  Visual reference: .claude/skills/airboard-design/ui_kits/airboard-app/onboarding.html
//  Presentation only: permission logic lives in SetupWindowController and is
//  reused as-is. Skippable from every step; skip behaves exactly like
//  finishing (the popover's permission card catches anything ungranted).
//

import SwiftUI
import AppKit

struct OnboardingFlow: View {
    enum Step: Int, CaseIterable {
        case welcome, gesture, microphone, accessibility, hotkey, tryIt

        var railNumber: String { String(format: "%02d", rawValue + 1) }
        var railTitle: String {
            switch self {
            case .welcome: return "Welcome"
            case .gesture: return "The gesture"
            case .microphone: return "Microphone"
            case .accessibility: return "Accessibility"
            case .hotkey: return "Your hotkey"
            case .tryIt: return "Try it live"
            }
        }
    }

    let onFinish: () -> Void
    @State private var step: Step

    init(initialStep: Step = .welcome, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        _step = State(initialValue: initialStep)
    }

    var body: some View {
        HStack(spacing: 0) {
            rail
            stage
        }
        .frame(width: 920, height: 640)
        .background(
            LinearGradient(colors: [Color(hex: 0x17171A), Color(hex: 0x101012)],
                           startPoint: .top, endPoint: .bottom)
        )
        .environment(\.colorScheme, .dark)
    }

    // MARK: Rail (left, 250pt): logo, numbered items, footer statline

    private var rail: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 54, height: 54)
                .padding(.bottom, 22)
            ForEach(Step.allCases, id: \.rawValue) { s in
                railItem(s)
            }
            Spacer()
            HStack(spacing: 8) {
                Circle().fill(DS.Accent.success).frame(width: 6, height: 6)
                Text("On-device · nothing leaves your Mac")
                    .font(DS.Typo.ui(11)).foregroundColor(DS.Label.secondary)
            }
        }
        .padding(EdgeInsets(top: 26, leading: 20, bottom: 22, trailing: 20))
        .frame(width: 250, alignment: .leading)
        .background(Color.black.opacity(0.14))
        .overlay(Rectangle().fill(DS.Border.hairline).frame(width: 1), alignment: .trailing)
    }

    private func railItem(_ s: Step) -> some View {
        let isCurrent = s == step
        let isDone = s.rawValue < step.rawValue
        return HStack(spacing: 12) {
            Text(s.railNumber)
                .font(DS.Typo.mono(11))
                .foregroundColor(isCurrent ? DS.Accent.primary
                                 : isDone ? DS.Accent.success : DS.Label.tertiary)
                .frame(width: 20, alignment: .leading)
            Text(s.railTitle)
                .font(DS.Typo.ui(13.5, .medium))
                .foregroundColor(DS.Label.primary)
            Spacer()
            if isDone {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Accent.success)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 11)
            .fill(isCurrent ? DS.Fill.hover : Color.clear))
        .opacity(isCurrent ? 1 : isDone ? 0.8 : 0.45)
        .contentShape(Rectangle())
        .onTapGesture { if isDone { step = s } }
    }

    // MARK: Stage (right): one step visible at a time

    private var stage: some View {
        ZStack {
            switch step {
            case .welcome:       WelcomeStep(next: { step = .gesture }, skip: onFinish)
            case .gesture:       GestureStep(next: { step = .microphone }, skip: onFinish)
            case .microphone:    MicrophoneStep(next: { step = .accessibility }, skip: onFinish)
            case .accessibility: AccessibilityStep(next: { step = .hotkey }, skip: onFinish)
            case .hotkey:        HotkeyStep(next: { step = .tryIt }, skip: onFinish)
            case .tryIt:         TryItStep(finish: onFinish, skip: onFinish)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.3), value: step)
        .transition(.opacity)
    }
}

// MARK: - Shared step scaffolding

/// Kick line + big headline + content + footer, padded like the reference
/// (40pt top, 46pt sides, 34pt bottom).
private struct StepChrome<Content: View, Footer: View>: View {
    let kick: String
    let headline: String
    let content: Content
    let footer: Footer

    init(kick: String, headline: String,
         @ViewBuilder content: () -> Content,
         @ViewBuilder footer: () -> Footer) {
        self.kick = kick
        self.headline = headline
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(kick.uppercased())
                .font(DS.Typo.mono(11))
                .kerning(1.6)
                .foregroundColor(DS.Label.tertiary)
            Text(headline)
                .font(.system(size: 38, weight: .semibold))
                .foregroundColor(DS.Label.primary)
                .padding(.top, 18)
            content
            Spacer()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(EdgeInsets(top: 40, leading: 46, bottom: 34, trailing: 46))
    }
}

private struct PrimaryButton: View {
    let title: String
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(DS.Typo.ui(14.5, .semibold))
                .foregroundColor(DS.Label.onAccent)
                .padding(.horizontal, 26).padding(.vertical, 13)
                .background(RoundedRectangle(cornerRadius: DS.Radius.r12)
                    .fill(DS.Accent.primary))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }
}

/// The quiet skip affordance — label-tertiary mono text, never a button chrome.
private struct SkipButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text("Skip setup")
                .font(DS.Typo.mono(11))
                .kerning(0.7)
                .foregroundColor(DS.Label.tertiary)
        }
        .buttonStyle(.plain)
    }
}

/// Footer row: primary CTA left, skip right.
private struct StepFooter: View {
    let title: String
    var disabled = false
    let next: () -> Void
    let skip: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            PrimaryButton(title: title, disabled: disabled, action: next)
            Spacer()
            SkipButton(action: skip)
        }
    }
}

/// SF-Mono-labelled keycap in the DS keycap treatment.
private struct Keycap: View {
    let glyph: String
    var label: String? = nil
    var size: CGFloat = 110
    var body: some View {
        VStack(spacing: 5) {
            Text(glyph).font(.system(size: size * 0.38))
                .foregroundColor(DS.Label.primary)
            if let label {
                Text(label.uppercased())
                    .font(DS.Typo.mono(11)).kerning(1.1)
                    .foregroundColor(DS.Label.tertiary)
            }
        }
        .frame(minWidth: size, minHeight: size)
        .background(
            RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x242428), Color(hex: 0x191919)],
                                     startPoint: .top, endPoint: .bottom))
        )
        .overlay(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
            .strokeBorder(DS.Border.control, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 12, y: 8)
    }
}

// MARK: - Steps 1–2 (static content)

private struct WelcomeStep: View {
    let next: () -> Void
    let skip: () -> Void
    var body: some View {
        StepChrome(kick: "transcribing…", headline: "Speak. It types.") {
            Text("Airboard turns your voice into text, anywhere your cursor blinks — email, code, chat. Everything runs on your Mac. No account, no cloud.")
                .font(DS.Typo.ui(14.5)).foregroundColor(DS.Label.secondary)
                .lineSpacing(5).frame(maxWidth: 430, alignment: .leading)
                .padding(.top, 16)
        } footer: {
            StepFooter(title: "Get started", next: next, skip: skip)
        }
    }
}

private struct GestureStep: View {
    let next: () -> Void
    let skip: () -> Void
    var body: some View {
        StepChrome(kick: "the whole product in one move", headline: "No app to open.") {
            HStack(spacing: 18) {
                Text("Hold.")
                Text("Speak.")
                Text("Release.")
            }
            .font(.system(size: 30, weight: .semibold))
            .foregroundColor(DS.Label.primary.opacity(0.9))
            .padding(.top, 22)
            HStack(spacing: 30) {
                Keycap(glyph: "⌥", label: "hold")
                Text("While the key is down, Airboard listens. The moment you let go, clean text lands at your cursor.")
                    .font(DS.Typo.ui(13)).foregroundColor(DS.Label.secondary)
                    .lineSpacing(4).frame(maxWidth: 230, alignment: .leading)
            }
            .padding(.top, 40)
        } footer: {
            StepFooter(title: "Continue", next: next, skip: skip)
        }
    }
}

// MARK: - Steps 3–4 (permissions — logic reused from SetupWindowController)

/// Permission chip in the reference's pchip treatment: tinted tile, title,
/// detail, trailing Enable button that flips to a green "Granted" state.
private struct PermissionChip: View {
    let icon: String
    let tint: Color
    let iconColor: Color
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 13) {
            RoundedRectangle(cornerRadius: 11)
                .fill(tint)
                .frame(width: 36, height: 36)
                .overlay(Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(iconColor))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(DS.Typo.ui(14, .medium)).foregroundColor(DS.Label.primary)
                Text(detail).font(DS.Typo.ui(12)).foregroundColor(DS.Label.secondary)
            }
            Spacer()
            if granted {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                    Text("Granted").font(DS.Typo.ui(12.5, .semibold))
                }
                .foregroundColor(DS.Accent.success)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 9).fill(DS.Tint.green))
            } else {
                Button(action: action) {
                    Text("Enable")
                        .font(DS.Typo.ui(12.5, .semibold))
                        .foregroundColor(DS.Label.primary)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 9).fill(DS.Fill.quaternary))
                        .overlay(RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(DS.Border.control, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(EdgeInsets(top: 13, leading: 14, bottom: 13, trailing: 14))
        .background(RoundedRectangle(cornerRadius: 14).fill(DS.Fill.hover))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(DS.Border.hairline, lineWidth: 1))
        .frame(maxWidth: 430)
    }
}

private struct MicrophoneStep: View {
    let next: () -> Void
    let skip: () -> Void
    @State private var granted = SetupWindowController.shared.isMicrophoneGranted
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        StepChrome(kick: "airboard's ears", headline: "Let it hear you.") {
            Text("Your voice is transcribed on this Mac — never stored, never uploaded.")
                .font(DS.Typo.ui(14.5)).foregroundColor(DS.Label.secondary)
                .lineSpacing(5).frame(maxWidth: 430, alignment: .leading)
                .padding(.top, 14)
            PermissionChip(
                icon: "mic.fill", tint: DS.Tint.red, iconColor: Color(hex: 0xFF7A70),
                title: "Microphone", detail: "Hear your voice — never stored, never uploaded",
                granted: granted,
                action: { SetupWindowController.shared.requestMicrophoneAccess() }
            )
            .padding(.top, 24)
        } footer: {
            // Continue enabled either way: denial is fixable later from the popover.
            StepFooter(title: "Continue", next: next, skip: skip)
        }
        .onReceive(poll) { _ in
            let now = SetupWindowController.shared.isMicrophoneGranted
            if now && !granted {
                granted = true
                // Auto-advance on grant (spec) — short beat so the state is seen.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { next() }
            } else {
                granted = now
            }
        }
    }
}

private struct AccessibilityStep: View {
    let next: () -> Void
    let skip: () -> Void
    @State private var granted = SetupWindowController.shared.isAccessibilityGranted
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        StepChrome(kick: "airboard's hands", headline: "Let it type for you.") {
            Text("Accessibility lets Airboard place text at your cursor in any app — only what you dictate, nothing else.")
                .font(DS.Typo.ui(14.5)).foregroundColor(DS.Label.secondary)
                .lineSpacing(5).frame(maxWidth: 430, alignment: .leading)
                .padding(.top, 14)
            PermissionChip(
                icon: "keyboard", tint: DS.Tint.purple, iconColor: Color(hex: 0xD08BFF),
                title: "Accessibility", detail: "Type into any app — only what you dictate",
                granted: granted,
                action: { SetupWindowController.shared.openAccessibilitySettings() }
            )
            .padding(.top, 24)
        } footer: {
            StepFooter(title: "Continue", next: next, skip: skip)
        }
        .onReceive(poll) { _ in
            let now = SetupWindowController.shared.isAccessibilityGranted
            if now && !granted {
                granted = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { next() }
            } else {
                granted = now
            }
        }
    }
}

// MARK: - Step 5 (hotkey — existing options, DS card treatment)

private struct HotkeyStep: View {
    let next: () -> Void
    let skip: () -> Void
    @State private var selected: HotkeyOption = HotkeyManager.primaryHotkey

    private var options: [HotkeyOption] {
        HotkeyOption.allCases.filter { $0 != HotkeyManager.commandModifierHotkey }
    }

    private func glyph(for option: HotkeyOption) -> String {
        switch option {
        case .rightOption, .leftOption: return "⌥"
        case .rightCommand, .leftCommand: return "⌘"
        case .rightControl: return "⌃"
        case .fn: return "fn"
        }
    }

    var body: some View {
        StepChrome(kick: "make it muscle memory", headline: "Pick your key.") {
            Text("The key you'll hold to talk. Change it anytime from the menu bar.")
                .font(DS.Typo.ui(14.5)).foregroundColor(DS.Label.secondary)
                .padding(.top, 14)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3),
                      spacing: 14) {
                ForEach(options, id: \.self) { option in
                    optionCard(option)
                }
            }
            .padding(.top, 26)
        } footer: {
            StepFooter(title: "Continue", next: next, skip: skip)
        }
    }

    private func optionCard(_ option: HotkeyOption) -> some View {
        let isOn = option == selected
        return VStack(spacing: 12) {
            Keycap(glyph: glyph(for: option), size: 56)
            Text(option.displayName)
                .font(DS.Typo.ui(13, .semibold))
                .foregroundColor(DS.Label.primary)
                .multilineTextAlignment(.center)
        }
        .padding(EdgeInsets(top: 20, leading: 12, bottom: 16, trailing: 12))
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 18)
            .fill(isOn ? DS.Tint.cardBlue : DS.Fill.hover))
        .overlay(RoundedRectangle(cornerRadius: 18)
            .strokeBorder(isOn ? DS.Border.selected : DS.Border.hairline, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            selected = option
            HotkeyManager.primaryHotkey = option
            NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
        }
    }
}

// MARK: - Step 6 (Try It — the REAL pipeline, not a simulation)

private struct TryItStep: View {
    let finish: () -> Void
    let skip: () -> Void
    @ObservedObject private var coordinator = TranscriptionCoordinator.shared
    @State private var text = ""
    @State private var hasTranscribed = false
    @State private var keyMonitor: Any?
    @FocusState private var editorFocused: Bool

    var body: some View {
        StepChrome(
            kick: hasTranscribed ? "setup complete" : "this is the real thing",
            headline: hasTranscribed ? "You're ready." : "Say something."
        ) {
            if !coordinator.isModelReady {
                downloadingCard.padding(.top, 20)
            } else {
                Text("Hold \(HotkeyManager.primaryHotkey.displayName) on your keyboard — yes, right now. Release to see it typed below.")
                    .font(DS.Typo.ui(14.5)).foregroundColor(DS.Label.secondary)
                    .lineSpacing(5).frame(maxWidth: 430, alignment: .leading)
                    .padding(.top, 14)
                TextEditor(text: $text)
                    .font(DS.Typo.ui(15))
                    .foregroundColor(DS.Label.primary)
                    .scrollContentBackground(.hidden)
                    .focused($editorFocused)
                    .padding(12)
                    .frame(maxWidth: 520, minHeight: 90, maxHeight: 120)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.3)))
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(coordinator.isRecording ? DS.Accent.recording : DS.Border.control,
                                      lineWidth: 1))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(coordinator.isRecording ? "Listening…"
                                 : coordinator.isTranscribing ? "Transcribing…"
                                 : "Your words land here…")
                                .font(DS.Typo.ui(15)).foregroundColor(DS.Label.tertiary)
                                .padding(.top, 20).padding(.leading, 17)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.top, 28)
            }
        } footer: {
            HStack(spacing: 14) {
                PrimaryButton(title: hasTranscribed ? "Finish setup" : "Try it first",
                              disabled: !hasTranscribed, action: finish)
                Spacer()
                Button(action: skip) {
                    Text("Skip & finish")
                        .font(DS.Typo.mono(11)).kerning(0.7)
                        .foregroundColor(DS.Label.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear {
            editorFocused = true
            installKeyMonitor()
        }
        .onDisappear(perform: removeKeyMonitor)
        .onReceive(coordinator.$lastTranscribedText.dropFirst()) { newText in
            guard let newText, !newText.isEmpty else { return }
            hasTranscribed = true
            // The real pipeline inserts into the focused editor via the
            // Accessibility path. If that was skipped/denied, insertion
            // silently fails — surface the transcript directly instead.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if text.isEmpty { text = newText }
            }
        }
    }

    private var downloadingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preparing the speech model…")
                .font(DS.Typo.ui(14, .medium)).foregroundColor(DS.Label.primary)
            ProgressView(value: coordinator.modelDownloadProgress)
                .tint(DS.Accent.download)
            Text("One-time download (~460 MB). You can skip and try later.")
                .font(DS.Typo.ui(12)).foregroundColor(DS.Label.secondary)
        }
        .padding(16)
        .frame(maxWidth: 430)
        .background(RoundedRectangle(cornerRadius: DS.Radius.r12).fill(DS.Fill.hover))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.r12)
            .strokeBorder(DS.Border.hairline, lineWidth: 1))
    }

    /// Global hotkey monitoring hasn't started yet (it starts on setup
    /// completion), so drive the REAL pipeline with a local key monitor —
    /// works without Accessibility because our window is key.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let hotkey = HotkeyManager.primaryHotkey
            guard event.keyCode == hotkey.keyCode, coordinator.isModelReady else { return event }
            if event.modifierFlags.contains(hotkey.modifierFlag) {
                coordinator.startRecording()
            } else {
                coordinator.stopRecording(mode: .dictation)
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}
```

- [ ] **Step 3: Rewrite SetupWindowController to host the flow**

Replace `Airboard/Airboard/SetupWindowController.swift` entirely with:

```swift
//
//  SetupWindowController.swift
//  Airboard
//
//  Hosts the guided onboarding flow (OnboardingFlow.swift) and owns the
//  battle-tested permission logic the flow's steps call into. Shown only
//  when setup is incomplete or a permission is missing — existing users
//  with granted permissions never see it.
//

import AppKit
import SwiftUI
import AVFoundation
import ApplicationServices

class SetupWindowController: NSObject, NSWindowDelegate {

    static let shared = SetupWindowController()

    private var window: NSWindow?
    private var onComplete: (() -> Void)?

    private let hasCompletedSetupKey = "hasCompletedSetup"

    var hasCompletedSetup: Bool {
        get { UserDefaults.standard.bool(forKey: hasCompletedSetupKey) }
        set { UserDefaults.standard.set(newValue, forKey: hasCompletedSetupKey) }
    }

    var isMicrophoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    var allPermissionsGranted: Bool {
        isMicrophoneGranted && isAccessibilityGranted
    }

    // MARK: - Start Setup

    func startSetupIfNeeded(completion: @escaping () -> Void) {
        self.onComplete = completion

        print("📋 Setup check: hasCompletedSetup=\(hasCompletedSetup), allPermissionsGranted=\(allPermissionsGranted)")

        if !hasCompletedSetup {
            showOnboarding(startingAt: .welcome)
        } else if !allPermissionsGranted {
            // Returning user with a revoked permission: jump straight to
            // the relevant permission step, no welcome tour.
            showOnboarding(startingAt: isMicrophoneGranted ? .accessibility : .microphone)
        } else {
            completion()
        }
    }

    func showPermissionSetup() {
        showOnboarding(startingAt: isMicrophoneGranted ? .accessibility : .microphone)
    }

    // MARK: - Window

    private func showOnboarding(startingAt step: OnboardingFlow.Step) {
        window?.close()

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newWindow.titlebarAppearsTransparent = true
        newWindow.titleVisibility = .hidden
        // Opaque DS surface — never .clear (the Sonoma click-through lesson).
        newWindow.backgroundColor = .dsSurfaceWindow
        newWindow.isMovableByWindowBackground = true
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self
        newWindow.contentView = NSHostingView(
            rootView: OnboardingFlow(initialStep: step) { [weak self] in
                self?.finishSetup()
            }
        )
        newWindow.center()

        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Permission actions (reused by OnboardingFlow's steps)

    func requestMicrophoneAccess() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        } else if status == .denied || status == .restricted {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Completion (finish and skip share this wiring)

    private func finishSetup() {
        hasCompletedSetup = true
        let completion = onComplete
        onComplete = nil
        window?.close()
        window = nil
        NotificationCenter.default.post(name: .pulseFloatingIcon, object: nil)
        completion?()
    }

    // MARK: - Window Delegate

    func windowWillClose(_ notification: Notification) {
        // Closing the window = skipping: same post-setup wiring as finishing.
        if !hasCompletedSetup { hasCompletedSetup = true }
        let completion = onComplete
        onComplete = nil
        completion?()
    }
}
```

Note what this deletes relative to the old file: the AppKit permission-card builders, the 1s `permissionCheckTimer`, the `didBecomeActiveNotification` observer, and `updateUI()` — the SwiftUI steps poll for themselves. Note also that the old file called `onComplete` twice on a normal finish (`completeSetup` → `window?.close()` → `windowWillClose` → `onComplete?()`, then `completeSetup`'s own `onComplete?()`); the nil-out-before-close pattern above fixes that.

- [ ] **Step 4: Build**

Run: `cd /Users/dhruvmehra/Desktop/proj/Airboard/Airboard && xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Smoke-check the fresh-install path compiles into the right flow**

Run: `grep -n "startSetupIfNeeded\|showPermissionSetup" Airboard/Airboard/*.swift`
Expected: callers unchanged — `AirboardApp.swift` (launch) and the popover/menubar permission entry points still compile against the same method names.

- [ ] **Step 6: Commit**

```bash
git add Airboard/Airboard/OnboardingFlow.swift Airboard/Airboard/SetupWindowController.swift Airboard/Airboard/TranscriptionCoordinator.swift
git commit -m "feat: guided onboarding flow (DS v2), replacing the setup window"
```

---

### Task 7: Docs + changelog

**Files:**
- Modify: `CHANGELOG.md` (`## [Unreleased]` section)
- Modify: `CLAUDE.md` (Source Organization table + UserDefaults notes)

**Interfaces:**
- Consumes: everything above (describes it).
- Produces: release notes for the next release.

- [ ] **Step 1: Update CHANGELOG.md**

Under `## [Unreleased]`, add:

```markdown
- New look: the entire app adopts the Airboard design system v2 "Sleek Dark" — dark-only, tokenized surfaces, blue-led actions
- New guided onboarding for first-run setup: six steps (Welcome → The Gesture → Microphone → Accessibility → Your Hotkey → Try It), skippable at any point; existing users never see it
```

- [ ] **Step 2: Update CLAUDE.md**

In the Source Organization table, add to the UI row: `DesignSystem.swift` (v2 tokens — all styled views consume these) and `OnboardingFlow.swift` (guided first-run flow hosted by `SetupWindowController`). Add one line under Build & Run: "The app forces dark appearance (`.darkAqua`) at launch — design system v2 is dark-only."

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md CLAUDE.md
git commit -m "docs: changelog + CLAUDE.md for design-system adoption"
```

---

## Manual Verification (run by the user — this is a visual project)

From the spec, after all tasks land (dev build via Xcode ⌘R):

1. Every surface side-by-side with its ui-kit screen: popover, cleanup, hotkey, performance, feedback, download modal, floating indicator.
2. Dark-only: switch macOS to light mode — the app renders identically.
3. Fresh-install onboarding: `defaults delete com.pype.airboard.dev hasCompletedSetup && tccutil reset Microphone com.pype.airboard.dev && tccutil reset Accessibility com.pype.airboard.dev`, relaunch → walk all six steps, grant both permissions, dictate in Try It, finish.
4. Skip path: reset again → Skip setup on step 1 → app fully usable; popover shows the permission card until granted.
5. Existing-user path: normal launch (setup already completed, permissions granted) shows NO onboarding.
6. Semantics spot-check: nothing red except recording state + logo; CTAs blue; switch green when on.
7. Regression: dictation, hands-free, command mode, mic picker, cleanup settings all behave exactly as before.
