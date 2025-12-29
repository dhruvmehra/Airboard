//
//  HotkeySettingsView.swift
//  Airboard
//
//  Created by Dhruv Mehra on 25/12/25.
//


//
//  HotkeySettingsView.swift
//  Airboard
//

import SwiftUI

struct HotkeySettingsView: View {
    @State private var selectedHotkey: HotkeyOption = HotkeyManager.currentHotkey
    @Environment(\.dismiss) private var dismiss
    var onHotkeyChanged: (() -> Void)?
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Choose Hotkey")
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
            
            // Description
            Text("Hold this key and speak to dictate")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .padding(.top, 16)
                .padding(.bottom, 12)
            
            // Options
            VStack(spacing: 8) {
                ForEach(HotkeyOption.allCases, id: \.self) { option in
                    HotkeyOptionRow(
                        option: option,
                        isSelected: selectedHotkey == option,
                        onSelect: {
                            selectedHotkey = option
                            HotkeyManager.currentHotkey = option
                            onHotkeyChanged?()
                        }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
        .frame(width: 300)
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
                // Checkmark
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundColor(isSelected ? .blue : .secondary.opacity(0.4))
                
                // Label
                Text(option.displayName)
                    .font(.system(size: 14))
                    .foregroundColor(.primary)
                
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
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