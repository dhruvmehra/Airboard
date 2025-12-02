//
//  FloatingWindowManager.swift
//
//  Created by Dhruv Mehra on 01/12/25.
//

import SwiftUI
import AppKit

class FloatingWindowManager {
    static let shared = FloatingWindowManager()
    private var floatingWindow: NSWindow?
    
    init() {
        DispatchQueue.main.async {
            self.createFloatingWindow()
            self.updateIndicatorState(isRecording: false, isTranscribing: false, isDownloading: false, downloadProgress: 0.0)
        }
    }
    
    func showFloatingIndicator(isRecording: Bool, isTranscribing: Bool) {
        DispatchQueue.main.async {
            self.updateIndicatorState(isRecording: isRecording, isTranscribing: isTranscribing, isDownloading: false, downloadProgress: 0.0)
        }
    }
    
    func showDownloadProgress(progress: Double) {
        DispatchQueue.main.async {
            self.updateIndicatorState(isRecording: false, isTranscribing: false, isDownloading: true, downloadProgress: progress)
        }
    }
    
    func hideFloatingIndicator() {
        DispatchQueue.main.async {
            self.updateIndicatorState(isRecording: false, isTranscribing: false, isDownloading: false, downloadProgress: 0.0)
        }
    }
    
    private func updateIndicatorState(isRecording: Bool, isTranscribing: Bool, isDownloading: Bool, downloadProgress: Double) {
        guard let window = self.floatingWindow else {
            createFloatingWindow()
            return
        }
        
        window.contentView = NSHostingView(
            rootView: FloatingIndicatorView(
                isRecording: isRecording,
                isTranscribing: isTranscribing,
                isDownloading: isDownloading,
                downloadProgress: downloadProgress
            )
        )
        
        window.alphaValue = 1.0
        window.orderFrontRegardless()
        
        let stateEmoji = isDownloading ? "📥" : (isRecording ? "🔴" : (isTranscribing ? "🟠" : "⚪️"))
        print("\(stateEmoji) Indicator state - Recording: \(isRecording), Transcribing: \(isTranscribing), Downloading: \(isDownloading) (\(Int(downloadProgress * 100))%)")
    }
    
    private func createFloatingWindow() {
        let windowSize: CGFloat = 52
        
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: windowSize, height: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let margin: CGFloat = 20
            let x = screenFrame.maxX - windowSize - margin
            let y = screenFrame.minY + margin
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
        
        floatingWindow = window
        window.alphaValue = 1.0
        window.orderFrontRegardless()
        
        print("✅ Always-visible floating indicator created")
    }
}

struct FloatingIndicatorView: View {
    let isRecording: Bool
    let isTranscribing: Bool
    let isDownloading: Bool
    let downloadProgress: Double
    
    @State private var pulseScale: CGFloat = 1.0
    
    var body: some View {
        ZStack {
            // Outer ring - only visible when active
            if isRecording || isTranscribing {
                Circle()
                    .stroke(accentColor.opacity(0.2), lineWidth: 2)
                    .frame(width: 46, height: 46)
                    .scaleEffect(pulseScale)
                    .opacity(2 - pulseScale) // Fades as it grows
                    .onAppear {
                        withAnimation(
                            .easeInOut(duration: 1.5)
                            .repeatForever(autoreverses: false)
                        ) {
                            pulseScale = 1.4
                        }
                    }
            }
            
            // Main container - layered depth
            ZStack {
                // Base shadow layer
                Circle()
                    .fill(Color.black.opacity(0.08))
                    .frame(width: 44, height: 44)
                    .offset(y: 1)
                
                // Main surface
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 44, height: 44)
                    .overlay(
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.2),
                                        Color.clear
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.5
                            )
                    )
                
                // Accent ring when active
                if isRecording || isTranscribing {
                    Circle()
                        .stroke(accentColor, lineWidth: 2)
                        .frame(width: 44, height: 44)
                }
                
                // Download progress
                if isDownloading {
                    Circle()
                        .trim(from: 0, to: downloadProgress)
                        .stroke(
                            Color.blue,
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                        )
                        .frame(width: 44, height: 44)
                        .rotationEffect(.degrees(-90))
                }
            }
            
            // Icon layer
            if isDownloading {
                VStack(spacing: 0) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.blue)
                    Text("\(Int(downloadProgress * 100))%")
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .foregroundStyle(.blue.opacity(0.8))
                }
            } else {
                Image(systemName: iconName)
                    .font(.system(size: iconSize, weight: .medium))
                    .foregroundStyle(iconColor)
                    .symbolEffect(.bounce, value: isRecording)
            }
        }
        .frame(width: 52, height: 52)
    }
    
    private var iconName: String {
        if isRecording {
            return "waveform"
        } else if isTranscribing {
            return "ellipsis"
        } else {
            return "waveform"
        }
    }
    
    private var iconSize: CGFloat {
        if isRecording {
            return 16
        } else if isTranscribing {
            return 14
        } else {
            return 14
        }
    }
    
    private var iconColor: Color {
        if isRecording {
            return .red
        } else if isTranscribing {
            return .orange
        } else {
            return .primary.opacity(0.4)
        }
    }
    
    private var accentColor: Color {
        isRecording ? .red : .orange
    }
}
