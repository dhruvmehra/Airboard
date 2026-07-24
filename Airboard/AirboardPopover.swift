//
//  AirboardPopover.swift
//  Airboard
//
//  Created by Dhruv Mehra on 09/12/25.
//

import SwiftUI

struct AirboardPopover: View {
    let isModelDownloaded: Bool
    let isModelDownloading: Bool
    let downloadProgress: Double
    let onDownloadModel: () -> Void
    let onRemoveModel: () -> Void
    let onOpenHotkeySettings: () -> Void
    let onOpenCleanupSettings: () -> Void
    let onOpenPerformance: () -> Void
    let onReportIssue: () -> Void
    let onCheckForUpdates: () -> Void
    let onDismiss: () -> Void

    @AppStorage("aiCleanupEnabled") private var aiCleanupEnabled = false
    @ObservedObject private var micManager = MicDeviceManager.shared
    @State private var isHoveringDownload = false
    @State private var isHoveringHotkey = false
    @State private var isHoveringPerformance = false
    @State private var isHoveringReport = false
    @State private var isHoveringUpdate = false
    @State private var isHoveringRemove = false
    @State private var isHoveringSetup = false
    @State private var showingRemoveConfirm = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                // The brand mark: the Airboard waveform is always brand red
                // (tokens: --brand-red) — never blue, never a gradient.
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(DS.Brand.red)

                Text("Airboard")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DS.Label.primary)
                
                Spacer()
                
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(DS.Label.tertiary)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)
            
            Divider()
                .padding(.horizontal, 12)
            
            // Permission Status Section (if needed)
            if !SetupWindowController.shared.allPermissionsGranted {
                permissionStatusView
                
                Divider()
                    .padding(.horizontal, 12)
            }
            
            // Actions Section
            VStack(spacing: 8) {
                // AI cleanup toggle + settings
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(DS.Tint.purple)
                            .frame(width: DS.Badge.size, height: DS.Badge.size)

                        Image(systemName: "wand.and.stars")
                            .font(.system(size: DS.Badge.glyph, weight: .medium))
                            .foregroundStyle(DS.Accent.command)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI Cleanup")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(DS.Label.primary)

                        Text("Grammar")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Label.secondary)
                    }

                    Spacer()

                    Toggle("", isOn: $aiCleanupEnabled)
                        .toggleStyle(GreenSwitchToggleStyle())
                        .labelsHidden()
                        .onChange(of: aiCleanupEnabled) { _, enabled in
                            // The toggle is honest: it can only be ON when
                            // cleanup can actually work (server + model, and
                            // an API key for that server unless it's local).
                            // Otherwise it snaps back off and takes the user
                            // to setup — which auto-enables on a valid save.
                            if enabled && !TranscriptRefiner.shared.isFullyConfigured {
                                aiCleanupEnabled = false
                                onOpenCleanupSettings()
                            }
                        }

                    Button(action: onOpenCleanupSettings) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12))
                            .foregroundColor(DS.Label.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cleanup server settings")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                // Microphone picker
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(DS.Tint.blue)
                            .frame(width: DS.Badge.size, height: DS.Badge.size)

                        Image(systemName: "mic.fill")
                            .font(.system(size: DS.Badge.glyph, weight: .medium))
                            .foregroundStyle(DS.Accent.primary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Microphone")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(DS.Label.primary)

                        Text(micManager.activeMicName)
                            .font(.system(size: 11))
                            .foregroundColor(DS.Label.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Menu {
                        ForEach(micManager.inputDevices) { device in
                            Button(action: { micManager.selectMic(uid: device.uid) }) {
                                if micManager.resolvedSelectionUID == device.uid {
                                    Label(device.name, systemImage: "checkmark")
                                } else {
                                    Text(device.name)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Label.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .onAppear { micManager.refreshDevices() }

                // Hotkey Settings Button
                Button(action: onOpenHotkeySettings) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(DS.Tint.purple)
                                .frame(width: DS.Badge.size, height: DS.Badge.size)

                            Image(systemName: "command.circle.fill")
                                .font(.system(size: DS.Badge.glyph, weight: .medium))
                                .foregroundStyle(DS.Accent.command)
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Hotkey")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(DS.Label.primary)
                            
                            Text(HotkeyManager.currentHotkeyDisplayName)
                                .font(.system(size: 11))
                                .foregroundColor(DS.Label.secondary)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DS.Label.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.r10)
                            .fill(isHoveringHotkey ? DS.Fill.hover : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .onHover { isHoveringHotkey = $0 }
                
                // Performance Button
                Button(action: onOpenPerformance) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(DS.Tint.green)
                                .frame(width: DS.Badge.size, height: DS.Badge.size)

                            Image(systemName: "gauge.with.dots.needle.67percent")
                                .font(.system(size: DS.Badge.glyph, weight: .medium))
                                .foregroundStyle(DS.Accent.success)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Performance")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(DS.Label.primary)

                            Text("View real-time metrics")
                                .font(.system(size: 11))
                                .foregroundColor(DS.Label.secondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DS.Label.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.r10)
                            .fill(isHoveringPerformance ? DS.Fill.hover : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .onHover { isHoveringPerformance = $0 }

                // Report Issue Button
                Button(action: onReportIssue) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(DS.Tint.orange)
                                .frame(width: DS.Badge.size, height: DS.Badge.size)

                            Image(systemName: "exclamationmark.bubble.fill")
                                .font(.system(size: DS.Badge.glyph, weight: .medium))
                                .foregroundStyle(DS.Accent.warning)
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Report Issue")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(DS.Label.primary)
                            
                            Text("Help improve transcription")
                                .font(.system(size: 11))
                                .foregroundColor(DS.Label.secondary)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DS.Label.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.r10)
                            .fill(isHoveringReport ? DS.Fill.hover : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .onHover { isHoveringReport = $0 }

                // Check for Updates Button (production builds only)
                if UpdaterManager.isEnabled {
                    Button(action: onCheckForUpdates) {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(DS.Tint.blue)
                                    .frame(width: DS.Badge.size, height: DS.Badge.size)

                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: DS.Badge.glyph, weight: .medium))
                                    .foregroundStyle(DS.Accent.primary)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Check for Updates")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(DS.Label.primary)

                                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                                    .font(.system(size: 11))
                                    .foregroundColor(DS.Label.secondary)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(DS.Label.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.r10)
                                .fill(isHoveringUpdate ? DS.Fill.hover : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { isHoveringUpdate = $0 }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .frame(width: 280)
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
        .confirmationDialog(
            "Remove AI Model?",
            isPresented: $showingRemoveConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove Model", role: .destructive) {
                onRemoveModel()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will free up 0.5 GB of storage. You can download it again anytime.")
        }
    }
    
    // MARK: - Permission Status View
    
    @ViewBuilder
    private var permissionStatusView: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(DS.Tint.orange)
                        .frame(width: DS.Badge.size, height: DS.Badge.size)

                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: DS.Badge.glyph, weight: .medium))
                        .foregroundStyle(DS.Accent.warning)
                }
                
                VStack(alignment: .leading, spacing: 3) {
                    Text("Setup Required")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Label.primary)
                    
                    Text(permissionStatusText())
                        .font(.system(size: 11))
                        .foregroundColor(DS.Label.secondary)
                }
                
                Spacer()
            }
            
            Button(action: {
                SetupWindowController.shared.showPermissionSetup()
            }) {
                HStack {
                    Image(systemName: "gear")
                        .font(.system(size: 12, weight: .medium))
                    Text("Set Up Permissions")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Label.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.r8)
                        .fill(DS.Accent.warning)
                )
            }
            .buttonStyle(.plain)
            .onHover { isHoveringSetup = $0 }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.r12)
                .fill(DS.Tint.cardOrange)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private func permissionStatusText() -> String {
        var missing: [String] = []
        if !SetupWindowController.shared.isMicrophoneGranted {
            missing.append("Microphone")
        }
        if !SetupWindowController.shared.isAccessibilityGranted {
            missing.append("Accessibility")
        }
        return "Missing: " + missing.joined(separator: ", ")
    }
    
    // MARK: - Model Status View
    
    @ViewBuilder
    private var modelStatusView: some View {
        if isModelDownloading {
            // Downloading state
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .stroke(DS.Fill.track, lineWidth: 3)
                            .frame(width: DS.Badge.size, height: DS.Badge.size)

                        Circle()
                            .trim(from: 0, to: downloadProgress)
                            .stroke(
                                DS.Accent.primary,
                                style: StrokeStyle(lineWidth: 3, lineCap: .round)
                            )
                            .frame(width: DS.Badge.size, height: DS.Badge.size)
                            .rotationEffect(.degrees(-90))

                        Text("\(Int(downloadProgress * 100))")
                            .font(DS.Typo.rounded(9, .bold))
                            .foregroundColor(DS.Accent.primary)
                    }
                    
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Downloading AI Model")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(DS.Label.primary)
                        
                        Text("\(Int(downloadProgress * 500)) of 500 MB")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Label.secondary)
                    }
                    
                    Spacer()
                }
                
                // Progress bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: DS.Radius.r3)
                            .fill(DS.Tint.blue)

                        RoundedRectangle(cornerRadius: DS.Radius.r3)
                            .fill(
                                LinearGradient(
                                    colors: [DS.Accent.primary, DS.Palette.cyan],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geometry.size.width * downloadProgress)
                    }
                }
                .frame(height: 6)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.r12)
                    .fill(DS.Tint.cardBlue)
            )
            
        } else if isModelDownloaded {
            // Model ready status
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(DS.Tint.green)
                        .frame(width: DS.Badge.size, height: DS.Badge.size)

                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: DS.Badge.glyph, weight: .medium))
                        .foregroundStyle(DS.Accent.success)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Model Ready")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Label.primary)

                    Text("On-device transcription active")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Label.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.r12)
                    .fill(DS.Tint.cardGreen)
            )

        } else {
            // Not downloaded - Show download option
            Button(action: onDownloadModel) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(DS.Tint.blue)
                            .frame(width: DS.Badge.size, height: DS.Badge.size)

                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(DS.Accent.primary)
                    }
                    
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Download AI Enhancements")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(DS.Label.primary)
                        
                        Text("Better formatting & spacing • 0.5 GB")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Label.secondary)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.Label.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.r12)
                        .fill(isHoveringDownload ? DS.Fill.hover : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.r12)
                                .strokeBorder(DS.Border.selected, lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
            .onHover { isHoveringDownload = $0 }
        }
    }
}

// MARK: - Visual Effect Blur

/// Custom-drawn switch: NSSwitch renders gray inside non-activating panels
/// (the popover never becomes key), so system tint APIs are ignored there.
/// Drawing the capsule ourselves guarantees the green on-state.
struct GreenSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Capsule()
                .fill(configuration.isOn ? DS.Accent.success : DS.Fill.track)
                .frame(width: 34, height: 20)
                .overlay(
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.15), radius: 1, x: 0, y: 1)
                        .padding(2)
                        .offset(x: configuration.isOn ? 7 : -7)
                )
                .animation(.spring(duration: 0.2), value: configuration.isOn)
        }
        .buttonStyle(.plain)
    }
}

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        DS.Surface.window
        
        VStack {
            AirboardPopover(
                isModelDownloaded: false,
                isModelDownloading: false,
                downloadProgress: 0.0,
                onDownloadModel: {},
                onRemoveModel: {},
                onOpenHotkeySettings: {},
                onOpenCleanupSettings: {},
                onOpenPerformance: {},
                onReportIssue: {},
                onCheckForUpdates: {},
                onDismiss: {}
            )
        }
    }
    .frame(width: 500, height: 400)
}
