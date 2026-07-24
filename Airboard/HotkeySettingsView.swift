//
//  HotkeySettingsView.swift
//  Airboard
//

import SwiftUI

struct HotkeySettingsView: View {
    @State private var selectedPrimaryHotkey: HotkeyOption = HotkeyManager.primaryHotkey
    @State private var selectedCommandModifier: HotkeyOption = HotkeyManager.commandModifierHotkey
    @Environment(\.dismiss) private var dismiss
    var onHotkeyChanged: (() -> Void)?
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Hotkey Settings")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(DS.Label.primary)

                Spacer()

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(DS.Label.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    
                    // Dictation Hotkey Section
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Dictation Hotkey")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(DS.Label.primary)

                        Text("Hold this key to dictate text")
                            .font(.system(size: 12))
                            .foregroundColor(DS.Label.secondary)
                        
                        VStack(spacing: 6) {
                            ForEach(HotkeyOption.allCases.filter { $0 != selectedCommandModifier }, id: \.self) { option in
                                HotkeyOptionRow(
                                    option: option,
                                    isSelected: selectedPrimaryHotkey == option,
                                    onSelect: {
                                        selectedPrimaryHotkey = option
                                        HotkeyManager.primaryHotkey = option
                                        onHotkeyChanged?()
                                    }
                                )
                            }
                        }
                    }
                    
                    Divider()
                    
                    // Command Modifier Section
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Command Modifier")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(DS.Label.primary)

                        Text("Hold with dictation key for voice commands")
                            .font(.system(size: 12))
                            .foregroundColor(DS.Label.secondary)
                        
                        VStack(spacing: 6) {
                            ForEach(HotkeyOption.allCases.filter { $0 != selectedPrimaryHotkey }, id: \.self) { option in
                                HotkeyOptionRow(
                                    option: option,
                                    isSelected: selectedCommandModifier == option,
                                    onSelect: {
                                        selectedCommandModifier = option
                                        HotkeyManager.commandModifierHotkey = option
                                        onHotkeyChanged?()
                                    }
                                )
                            }
                        }
                    }
                    
                    Divider()
                    
                    // Instructions
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Dictation", systemImage: "waveform")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(DS.Accent.recording)
                        Text("Hold \(selectedPrimaryHotkey.displayName) and speak")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Label.secondary)

                        Label("Voice Command", systemImage: "bolt.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(DS.Accent.command)
                            .padding(.top, 4)
                        Text("Hold \(selectedPrimaryHotkey.displayName) + \(selectedCommandModifier.displayName) and speak")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Label.secondary)
                    }
                    .padding(.vertical, 8)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
        .frame(width: 300, height: 500)
        .background(DS.Surface.panel)
    }
}

struct HotkeyOptionRow: View {
    let option: HotkeyOption
    let isSelected: Bool
    let onSelect: () -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundColor(isSelected ? DS.Accent.primary : DS.Label.tertiary)

                Text(option.displayName)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Label.primary)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.r8)
                    .fill(isSelected ? DS.Tint.blue : (isHovering ? DS.Fill.hover : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.r8)
                    .stroke(isSelected ? DS.Border.selected : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

#Preview {
    HotkeySettingsView()
}
