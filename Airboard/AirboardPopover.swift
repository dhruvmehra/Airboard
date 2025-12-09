//
//  AirboardPopover.swift
//  Airboard
//
//  Created by Dhruv Mehra on 09/12/25.
//


//
//  AirboardPopover.swift
//  Airboard
//
//  Elegant Apple-style popover for Airboard controls
//

import SwiftUI

struct AirboardPopover: View {
    let isModelDownloaded: Bool
    let isModelDownloading: Bool
    let downloadProgress: Double
    let onDownloadModel: () -> Void
    let onRemoveModel: () -> Void
    let onReportIssue: () -> Void
    let onDismiss: () -> Void
    
    @State private var isHoveringDownload = false
    @State private var isHoveringReport = false
    @State private var isHoveringRemove = false
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
            
            // Model Status Section
            VStack(spacing: 12) {
                modelStatusView
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            
            Divider()
                .padding(.horizontal, 12)
            
            // Actions Section
            VStack(spacing: 8) {
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
            Text("This will free up 1.3 GB of storage. You can download it again anytime.")
        }
    }
    
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
                        
                        Text("\(Int(downloadProgress * 1300)) of 1,300 MB")
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
            // Downloaded state - Show remove option
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.15))
                        .frame(width: 32, height: 32)
                    
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.green)
                }
                
                VStack(alignment: .leading, spacing: 3) {
                    Text("AI Enhancements Active")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                    
                    Text("Better formatting & spacing")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(action: { showingRemoveConfirm = true }) {
                    Text("Remove")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.red)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.red.opacity(isHoveringRemove ? 0.15 : 0.1))
                        )
                }
                .buttonStyle(.plain)
                .onHover { isHoveringRemove = $0 }
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
                        
                        Text("Better formatting & spacing • 1.3 GB")
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
                onReportIssue: {},
                onDismiss: {}
            )
        }
    }
    .frame(width: 500, height: 400)
}