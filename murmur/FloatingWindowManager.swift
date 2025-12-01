//
//  FloatingWindowManager.swift
//  murmur
//
//  Created by Dhruv Mehra on 01/12/25.
//

import SwiftUI
import AppKit

class FloatingWindowManager {
    static let shared = FloatingWindowManager()
    private var floatingWindow: NSWindow?
    
    init() {
        // Create window on main thread
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
        // Don't actually hide - just return to idle state
        DispatchQueue.main.async {
            self.updateIndicatorState(isRecording: false, isTranscribing: false, isDownloading: false, downloadProgress: 0.0)
        }
    }
    
    private func updateIndicatorState(isRecording: Bool, isTranscribing: Bool, isDownloading: Bool, downloadProgress: Double) {
        guard let window = self.floatingWindow else {
            createFloatingWindow()
            return
        }
        
        // Update content with new state
        window.contentView = NSHostingView(
            rootView: FloatingIndicatorView(
                isRecording: isRecording,
                isTranscribing: isTranscribing,
                isDownloading: isDownloading,
                downloadProgress: downloadProgress
            )
        )
        
        // Make sure it's visible
        window.alphaValue = 1.0
        window.orderFrontRegardless()
        
        let stateEmoji = isDownloading ? "📥" : (isRecording ? "🔴" : (isTranscribing ? "🟠" : "⚪️"))
        print("\(stateEmoji) Indicator state - Recording: \(isRecording), Transcribing: \(isTranscribing), Downloading: \(isDownloading) (\(Int(downloadProgress * 100))%)")
    }
    
    private func createFloatingWindow() {
        let windowSize: CGFloat = 44
        
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: windowSize, height: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        // Native macOS floating window settings
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        
        // Position in bottom-right corner
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let margin: CGFloat = 20
            let x = screenFrame.maxX - windowSize - margin
            let y = screenFrame.minY + margin
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
        
        floatingWindow = window
        
        // Show immediately
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
    
    var body: some View {
        ZStack {
            // Subtle outer glow when active - CIRCULAR
            if isRecording || isTranscribing {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                statusColor.opacity(0.15),
                                statusColor.opacity(0)
                            ],
                            center: .center,
                            startRadius: 12,
                            endRadius: 22
                        )
                    )
                    .frame(width: 44, height: 44)
                    .blur(radius: 2)
                    .clipShape(Circle())
                    .compositingGroup()
            }
            
            // Main orb - clean glass effect
            Circle()
                .fill(.regularMaterial)
                .frame(width: 36, height: 36)
                .overlay(
                    Circle()
                        .stroke(strokeColor, lineWidth: 1)
                )
                .overlay(
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.1),
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: 1)
            
            // Download progress ring (when downloading)
            if isDownloading {
                Circle()
                    .trim(from: 0, to: downloadProgress)
                    .stroke(
                        Color.blue,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
                    .frame(width: 38, height: 38)
                    .rotationEffect(.degrees(-90))
            }
            
            // Icon - changes based on state
            if isDownloading {
                VStack(spacing: 2) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.blue)
                    Text("\(Int(downloadProgress * 100))%")
                        .font(.system(size: 7, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.blue)
                }
            } else {
                Image(systemName: iconName)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(iconColor)
            }
        }
        .animation(nil, value: isRecording) // Disable all animations
        .animation(nil, value: isTranscribing) // Disable all animations
    }
    
    // Icon changes based on state
    private var iconName: String {
        if isDownloading {
            return "arrow.down.circle.fill"
        } else if isRecording {
            return "waveform.circle.fill"
        } else if isTranscribing {
            return "waveform.circle"
        } else {
            return "waveform"
        }
    }
    
    // Colors
    private var iconColor: Color {
        if isDownloading {
            return Color.blue
        } else if isRecording {
            return Color(red: 1.0, green: 0.27, blue: 0.23)
        } else if isTranscribing {
            return Color(red: 1.0, green: 0.58, blue: 0.0)
        } else {
            return Color.gray.opacity(0.6)
        }
    }
    
    private var strokeColor: Color {
        if isDownloading {
            return Color.blue.opacity(0.2)
        } else if isRecording {
            return Color(red: 1.0, green: 0.27, blue: 0.23).opacity(0.2)
        } else if isTranscribing {
            return Color(red: 1.0, green: 0.58, blue: 0.0).opacity(0.2)
        } else {
            return Color.white.opacity(0.1)
        }
    }
    
    private var statusColor: Color {
        if isRecording {
            return Color(red: 1.0, green: 0.27, blue: 0.23)
        } else {
            return Color(red: 1.0, green: 0.58, blue: 0.0)
        }
    }
    
    private var shadowColor: Color {
        if isDownloading {
            return Color.blue.opacity(0.2)
        } else if isRecording {
            return Color(red: 1.0, green: 0.27, blue: 0.23).opacity(0.25)
        } else if isTranscribing {
            return Color(red: 1.0, green: 0.58, blue: 0.0).opacity(0.2)
        } else {
            return Color.black.opacity(0.08)
        }
    }
    
    private var shadowRadius: CGFloat {
        isRecording ? 10 : (isTranscribing ? 6 : 3)
    }
}
