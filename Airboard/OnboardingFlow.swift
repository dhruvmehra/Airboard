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
import Combine

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
                              disabled: !hasTranscribed, action: { removeKeyMonitor(); finish() })
                Spacer()
                Button(action: { removeKeyMonitor(); skip() }) {
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
        .onReceive(coordinator.$lastTranscribedText.dropFirst().receive(on: DispatchQueue.main)) { newText in
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
