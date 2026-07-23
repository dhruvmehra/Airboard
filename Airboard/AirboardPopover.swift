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
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .cyan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                
                Text("Airboard")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                
                Spacer()
                
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary.opacity(0.6))
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
                            .fill(Color.purple.opacity(0.1))
                            .frame(width: 32, height: 32)

                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.purple)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI cleanup")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.primary)

                        Text("Grammar")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Toggle("", isOn: $aiCleanupEnabled)
                        .toggleStyle(GreenSwitchToggleStyle())
                        .labelsHidden()
                        .onChange(of: aiCleanupEnabled) { _, enabled in
                            // Turning cleanup on with no server configured
                            // can't do anything yet — take the user straight
                            // to the setup screen.
                            if enabled && !TranscriptRefiner.shared.isConfigured {
                                onOpenCleanupSettings()
                            }
                        }

                    Button(action: onOpenCleanupSettings) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cleanup server settings")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                // Hotkey Settings Button
                Button(action: onOpenHotkeySettings) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.purple.opacity(isHoveringHotkey ? 0.15 : 0.1))
                                .frame(width: 32, height: 32)
                            
                            Image(systemName: "command.circle.fill")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Color.purple)
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Hotkey")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.primary)
                            
                            Text(HotkeyManager.currentHotkeyDisplayName)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.primary.opacity(isHoveringHotkey ? 0.04 : 0))
                    )
                }
                .buttonStyle(.plain)
                .onHover { isHoveringHotkey = $0 }
                
                // Performance Button
                Button(action: onOpenPerformance) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.green.opacity(isHoveringPerformance ? 0.15 : 0.1))
                                .frame(width: 32, height: 32)

                            Image(systemName: "gauge.with.dots.needle.67percent")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Color.green)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Performance")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.primary)

                            Text("View real-time metrics")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.primary.opacity(isHoveringPerformance ? 0.04 : 0))
                    )
                }
                .buttonStyle(.plain)
                .onHover { isHoveringPerformance = $0 }

                // Report Issue Button
                Button(action: onReportIssue) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.orange.opacity(isHoveringReport ? 0.15 : 0.1))
                                .frame(width: 32, height: 32)
                            
                            Image(systemName: "exclamationmark.bubble.fill")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Color.orange)
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Report Issue")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.primary)
                            
                            Text("Help improve transcription")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.primary.opacity(isHoveringReport ? 0.04 : 0))
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
                                    .fill(Color.blue.opacity(isHoveringUpdate ? 0.15 : 0.1))
                                    .frame(width: 32, height: 32)

                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Color.blue)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Check for Updates")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.primary)

                                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.primary.opacity(isHoveringUpdate ? 0.04 : 0))
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
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.3),
                                    Color.white.opacity(0.1)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.black.opacity(0.3), radius: 20, x: 0, y: 10)
        .shadow(color: Color.black.opacity(0.1), radius: 1, x: 0, y: 1)
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
                        .fill(Color.orange.opacity(0.15))
                        .frame(width: 32, height: 32)
                    
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.orange)
                }
                
                VStack(alignment: .leading, spacing: 3) {
                    Text("Setup Required")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                    
                    Text(permissionStatusText())
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
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
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.orange)
                )
            }
            .buttonStyle(.plain)
            .onHover { isHoveringSetup = $0 }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.08))
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
                            .stroke(Color.blue.opacity(0.2), lineWidth: 3)
                            .frame(width: 32, height: 32)
                        
                        Circle()
                            .trim(from: 0, to: downloadProgress)
                            .stroke(
                                Color.blue,
                                style: StrokeStyle(lineWidth: 3, lineCap: .round)
                            )
                            .frame(width: 32, height: 32)
                            .rotationEffect(.degrees(-90))
                        
                        Text("\(Int(downloadProgress * 100))")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundColor(.blue)
                    }
                    
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Downloading AI Model")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.primary)
                        
                        Text("\(Int(downloadProgress * 500)) of 500 MB")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                }
                
                // Progress bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.blue.opacity(0.15))
                        
                        RoundedRectangle(cornerRadius: 3)
                            .fill(
                                LinearGradient(
                                    colors: [.blue, .cyan],
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
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.blue.opacity(0.06))
            )
            
        } else if isModelDownloaded {
            // Model ready status
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.15))
                        .frame(width: 32, height: 32)

                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.green)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Model Ready")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)

                    Text("On-device transcription active")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.green.opacity(0.06))
            )

        } else {
            // Not downloaded - Show download option
            Button(action: onDownloadModel) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.blue.opacity(isHoveringDownload ? 0.15 : 0.1))
                            .frame(width: 32, height: 32)
                        
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color.blue)
                    }
                    
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Download AI Enhancements")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.primary)
                        
                        Text("Better formatting & spacing • 0.5 GB")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.primary.opacity(isHoveringDownload ? 0.04 : 0))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.blue.opacity(0.2), lineWidth: 1)
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
                .fill(configuration.isOn ? Color.green : Color.primary.opacity(0.2))
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
        Color.gray.opacity(0.3)
        
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
