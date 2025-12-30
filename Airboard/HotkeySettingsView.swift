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
                
                Spacer()
                
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary.opacity(0.6))
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
                        
                        Text("Hold this key to dictate text")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        
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
                        
                        Text("Hold with dictation key for voice commands")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        
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
                            .foregroundColor(.red)
                        Text("Hold \(selectedPrimaryHotkey.displayName) and speak")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        
                        Label("Voice Command", systemImage: "bolt.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.purple)
                            .padding(.top, 4)
                        Text("Hold \(selectedPrimaryHotkey.displayName) + \(selectedCommandModifier.displayName) and speak")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
        .frame(width: 300, height: 500)
        .background(Color(NSColor.windowBackgroundColor))
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
                    .foregroundColor(isSelected ? .blue : .secondary.opacity(0.4))
                
                Text(option.displayName)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.blue.opacity(0.1) : (isHovering ? Color.primary.opacity(0.05) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.blue.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

#Preview {
    HotkeySettingsView()
}
