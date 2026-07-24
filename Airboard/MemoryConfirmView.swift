//
//  MemoryConfirmView.swift
//
//  The memory confirmation card: every "remember…" fact is shown here for
//  edit/save before anything is stored (spec: nothing stored silently).
//  DS v2 HUD language — same surface as the popover/toast family. Hosted
//  in a KEY-ACCEPTING panel (it takes typing), so native controls render
//  normally; the non-activating-panel lesson does not apply here.
//

import SwiftUI

struct MemoryConfirmView: View {
    @State var text: String
    let onSave: (String) -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(DS.Tint.purple)
                        .frame(width: 24, height: 24)
                    Image(systemName: "brain")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DS.Accent.command)
                }
                Text("Remember this?")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Label.primary)
                Spacer()
                Text("⏎ save · esc cancel")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(DS.Label.tertiary)
            }

            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(DS.Label.primary)
                .lineLimit(1...4)
                .focused($focused)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: DS.Radius.r8).fill(DS.Surface.control))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.r8)
                    .stroke(DS.Border.control, lineWidth: 1))
                .onSubmit { if canSave { onSave(text) } }

            HStack(spacing: 8) {
                Text("Edits teach Airboard the right spelling.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Label.secondary)
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Label.secondary)
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Save") { onSave(text) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Label.onAccent)
                    .padding(.horizontal, 14).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.r8)
                        .fill(DS.Accent.primary))
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.4)
                    .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(14)
        .frame(width: 420)
        .background(RoundedRectangle(cornerRadius: DS.Radius.r12, style: .continuous)
            .fill(DS.Surface.hud))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.r12, style: .continuous)
            .strokeBorder(DS.Surface.hudBorder, lineWidth: 1))
        .onAppear { focused = true }
    }
}
