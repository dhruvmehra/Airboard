//
//  FloatingWindowManager.swift
//  Airboard
//
//  Manages floating indicator and elegant popover
//

import SwiftUI
import AppKit

class FloatingWindowManager {
    static let shared = FloatingWindowManager()
    private var floatingWindow: NSWindow?
    private var popoverWindow: NSWindow?
    
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
                downloadProgress: downloadProgress,
                onTap: { [weak self] in
                    self?.handleTap(isRecording: isRecording, isTranscribing: isTranscribing)
                }
            )
        )
        
        window.alphaValue = 1.0
        window.orderFrontRegardless()
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
        window.ignoresMouseEvents = false
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
        
        print("✅ Clickable floating indicator created")
    }
    
    private func handleTap(isRecording: Bool, isTranscribing: Bool) {
        guard !isRecording && !isTranscribing else { return }
        print("🖱️ Floating icon tapped")
        
        // Toggle popover
        if popoverWindow != nil {
            hidePopover()
        } else {
            showPopover()
        }
    }
    
    private func showPopover() {
        guard let floatingWindow = floatingWindow,
              let screen = NSScreen.main else { return }
        
        let isModelDownloaded = ModelDownloadManager.shared.isModelReady
        let isModelDownloading = ModelDownloadManager.shared.isDownloading
        let downloadProgress = ModelDownloadManager.shared.downloadProgress
        
        let popoverView = AirboardPopover(
            isModelDownloaded: isModelDownloaded,
            isModelDownloading: isModelDownloading,
            downloadProgress: downloadProgress,
            onDownloadModel: { [weak self] in
                self?.handleDownloadModel()
            },
            onRemoveModel: { [weak self] in
                self?.handleRemoveModel()
            },
            onReportIssue: { [weak self] in
                self?.handleReportIssue()
            },
            onDismiss: { [weak self] in
                self?.hidePopover()
            }
        )
        
        let popoverWidth: CGFloat = 280
        let popoverHeight: CGFloat = 300
        
        let hostingView = NSHostingView(rootView: popoverView)
        hostingView.frame = NSRect(x: 0, y: 0, width: popoverWidth, height: popoverHeight)
        
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: popoverWidth, height: popoverHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        window.contentView = hostingView
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        
        // Smart positioning to keep popover on screen
        let floatingFrame = floatingWindow.frame
        let screenFrame = screen.visibleFrame
        let margin: CGFloat = 10
        
        // Center horizontally relative to floating icon
        var popoverX = floatingFrame.origin.x - (popoverWidth - floatingFrame.width) / 2
        
        // Ensure it doesn't go off the right edge
        if popoverX + popoverWidth > screenFrame.maxX {
            popoverX = screenFrame.maxX - popoverWidth - margin
        }
        
        // Ensure it doesn't go off the left edge
        if popoverX < screenFrame.minX {
            popoverX = screenFrame.minX + margin
        }
        
        // Position above the icon (going UP the screen)
        var popoverY = floatingFrame.origin.y + floatingFrame.height + margin
        
        // Check if popover would go off the top of screen
        if popoverY + popoverHeight > screenFrame.maxY {
            // Not enough space above, position below the icon instead
            popoverY = floatingFrame.origin.y - popoverHeight - margin
            
            // If also not enough space below, just put it at top with margin
            if popoverY < screenFrame.minY {
                popoverY = screenFrame.maxY - popoverHeight - margin
            }
        }
        
        window.setFrameOrigin(NSPoint(x: popoverX, y: popoverY))
        
        // Animate in
        window.alphaValue = 0
        window.orderFrontRegardless()
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1.0
        }
        
        popoverWindow = window
        
        // Auto-hide when clicking outside
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                if let popoverWindow = self?.popoverWindow,
                   !popoverWindow.frame.contains(event.locationInWindow) {
                    self?.hidePopover()
                }
            }
        }
    }
    
    private func hidePopover() {
        guard let window = popoverWindow else { return }
        
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: {
            window.close()
            self.popoverWindow = nil
        })
    }
    
    // MARK: - Actions
    
    private func handleDownloadModel() {
        hidePopover()
        ModelDownloadManager.shared.downloadModel()
    }
    
    private func handleRemoveModel() {
        hidePopover()
        ModelDownloadManager.shared.deleteModel()
    }
    
    private func handleReportIssue() {
        hidePopover()
        NotificationCenter.default.post(name: .openFeedbackReport, object: nil)
    }
    
    func cleanup() {
        DispatchQueue.main.async {
            self.popoverWindow?.close()
            self.popoverWindow = nil
            self.floatingWindow?.orderOut(nil)
            self.floatingWindow?.close()
            self.floatingWindow = nil
            print("🧹 Floating window cleaned up")
        }
    }
}

// MARK: - Floating Indicator View

struct FloatingIndicatorView: View {
    let isRecording: Bool
    let isTranscribing: Bool
    let isDownloading: Bool
    let downloadProgress: Double
    let onTap: () -> Void
    
    @State private var pulseScale: CGFloat = 1.0
    @State private var isHovered = false
    
    var body: some View {
        Button(action: onTap) {
            ZStack {
                // Pulse animation (background)
                if isRecording || isTranscribing {
                    Circle()
                        .stroke(accentColor.opacity(0.2), lineWidth: 2)
                        .frame(width: 46, height: 46)
                        .scaleEffect(pulseScale)
                        .opacity(2 - pulseScale)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
                                pulseScale = 1.4
                            }
                        }
                }
                
                // Main circle background
                Circle()
                    .fill(Color.black.opacity(0.08))
                    .frame(width: 44, height: 44)
                    .offset(y: 1)
                
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 44, height: 44)
                    .overlay(
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.2), Color.clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.5
                            )
                    )
                    .overlay(
                        Circle()
                            .stroke(Color.blue.opacity(isHovered ? 0.6 : 0), lineWidth: 2)
                    )
                
                // Status ring
                if isRecording || isTranscribing {
                    Circle()
                        .stroke(accentColor, lineWidth: 2)
                        .frame(width: 44, height: 44)
                }
                
                if isDownloading {
                    Circle()
                        .trim(from: 0, to: downloadProgress)
                        .stroke(Color.blue, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .frame(width: 44, height: 44)
                        .rotationEffect(.degrees(-90))
                }
                
                // Icon on top
                if isDownloading {
                    VStack(spacing: 0) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.blue)
                        Text("\(Int(downloadProgress * 100))%")
                            .font(.system(size: 8, weight: .semibold, design: .rounded))
                            .foregroundStyle(.blue.opacity(0.8))
                    }
                    .allowsHitTesting(false)  // ← Important!
                } else {
                    Image(systemName: iconName)
                        .font(.system(size: iconSize, weight: .medium))
                        .foregroundStyle(iconColor)
                        .symbolEffect(.bounce, value: isRecording)
                        .allowsHitTesting(false)  // ← Important!
                }
            }
            .frame(width: 52, height: 52)
            .contentShape(Rectangle())  // ← Important! Makes entire area clickable
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Airboard")
    }
    
    private var iconName: String {
        if isRecording { return "waveform" }
        if isTranscribing { return "ellipsis" }
        return "waveform"
    }
    
    private var iconSize: CGFloat {
        isRecording ? 16 : 14
    }
    
    private var iconColor: Color {
        if isRecording { return .red }
        if isTranscribing { return .orange }
        return .primary.opacity(0.4)
    }
    
    private var accentColor: Color {
        isRecording ? .red : .orange
    }
}
