//
//  VocabularyCardView.swift
//
//  The vocabulary confirm card. MUST NOT take focus: the user keeps
//  typing while it's up (unlike MemoryConfirmView, which is key-accepting).
//  Non-activating, never-key panel; buttons accept the first click.
//  Ignored for 8s → .ignored (Learned = Keep, Did you mean = snooze).
//

import SwiftUI
import AppKit

struct VocabularyCardView: View {
    let card: VocabularyCard
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(DS.Tint.purple).frame(width: 24, height: 24)
                Image(systemName: card.kind == .learned ? "brain" : "questionmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.Accent.command)
            }
            Group {
                if card.kind == .learned {
                    Text("Learned: \(card.heard) → ") + Text(card.term).bold()
                } else {
                    Text("Did you mean ") + Text(card.term).bold() + Text("?")
                }
            }
            .font(.system(size: 12))
            .foregroundColor(DS.Label.primary)
            .lineLimit(2)
            .frame(maxWidth: 300, alignment: .leading)
            Button(card.kind == .learned ? "Undo" : "No", action: onSecondary)
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(DS.Label.secondary)
            Button(card.kind == .learned ? "Keep" : "Yes", action: onPrimary)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Label.onAccent)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: DS.Radius.r8).fill(DS.Accent.primary))
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: DS.Radius.r12, style: .continuous).fill(DS.Surface.hud))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.r12, style: .continuous)
            .strokeBorder(DS.Surface.hudBorder, lineWidth: 1))
        .fixedSize()
    }
}

/// Never becomes key → the user's app keeps keyboard focus.
private final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Buttons respond to the first click without activating Airboard.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class VocabularyCardPresenter {
    static let shared = VocabularyCardPresenter()
    static let ignoreAfter: TimeInterval = 8

    private var panel: NSPanel?
    private var generation = 0

    func show(_ card: VocabularyCard, onChoice: @escaping (VocabularyCardChoice) -> Void) {
        dismiss()
        generation += 1
        let gen = generation
        var answered = false
        let finish: (VocabularyCardChoice) -> Void = { [weak self] choice in
            guard !answered, let self, gen == self.generation else { return }
            answered = true
            self.dismiss()
            onChoice(choice)
        }
        guard let screen = FloatingWindowManager.shared.activeScreen ?? NSScreen.main else { return }
        let hosting = FirstMouseHostingView(rootView: VocabularyCardView(
            card: card, onPrimary: { finish(.primary) }, onSecondary: { finish(.secondary) }))
        let size = hosting.fittingSize
        let frame = NSRect(x: screen.visibleFrame.maxX - size.width - 16,
                           y: screen.visibleFrame.maxY - size.height - 16,
                           width: size.width, height: size.height)
        let p = NonKeyPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.ignoresMouseEvents = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentView = hosting
        p.orderFrontRegardless()
        panel = p
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.ignoreAfter) { finish(.ignored) }
    }

    func dismiss() {
        panel?.close()
        panel = nil
    }
}
