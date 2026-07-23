//
//  FloatingWindowManager.swift
//  Airboard
//
//  Manages floating indicator and elegant popover
//

import SwiftUI
import AppKit
import Combine

class FloatingWindowManager: NSObject {
    static let shared = FloatingWindowManager()
    private var floatingWindow: NSWindow?
    private var popoverWindow: NSWindow?
    private var hotkeyWindow: NSWindow?
    private var cleanupSettingsWindow: NSWindow?
    private var performanceWindow: NSWindow?

    // Auto-hide state
    private var isHidden = false
    
    override init() {
        super.init()

        DispatchQueue.main.async { [weak self] in
            self?.createFloatingWindow()
            self?.updateIndicatorState(isRecording: false, isTranscribing: false, isCommandMode: false, isDownloading: false, downloadProgress: 0.0)
        }

        // Listen for pulse notification (for onboarding)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pulseIcon),
            name: .pulseFloatingIcon,
            object: nil
        )

        // Listen for screen configuration changes (resolution, display arrangement, etc.)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }
    
    func showFloatingIndicator(isRecording: Bool, isTranscribing: Bool, isCommandMode: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            self?.updateIndicatorState(isRecording: isRecording, isTranscribing: isTranscribing, isCommandMode: isCommandMode, isDownloading: false, downloadProgress: 0.0)
            self?.showIcon() // Show icon when there's activity
        }
    }
    
    func showDownloadProgress(progress: Double) {
        DispatchQueue.main.async { [weak self] in
            DownloadState.shared.progress = progress
            self?.updateIndicatorState(isRecording: false, isTranscribing: false, isCommandMode: false, isDownloading: true, downloadProgress: progress)
        }
    }
    
    func hideFloatingIndicator() {
        DispatchQueue.main.async { [weak self] in
            self?.updateIndicatorState(isRecording: false, isTranscribing: false, isCommandMode: false, isDownloading: false, downloadProgress: 0.0)
            // If the download modal is still up, the model is ready now — close it.
            self?.downloadModalWindow?.close()
            self?.downloadModalWindow = nil
        }
    }
    
    func showCommandExecuted() {
        // Brief flash to indicate command was executed
        DispatchQueue.main.async { [weak self] in
            self?.flashSuccess()
        }
    }
    
    private func updateIndicatorState(isRecording: Bool, isTranscribing: Bool, isCommandMode: Bool, isDownloading: Bool, downloadProgress: Double) {
        guard let window = self.floatingWindow else {
            createFloatingWindow()
            return
        }

        window.contentView = NSHostingView(
            rootView: FloatingIndicatorView(
                isRecording: isRecording,
                isTranscribing: isTranscribing,
                isCommandMode: isCommandMode,
                isDownloading: isDownloading,
                downloadProgress: downloadProgress,
                onTap: { [weak self] in
                    self?.showIcon() // Show icon when tapped
                    self?.handleTap(isRecording: isRecording, isTranscribing: isTranscribing)
                }
            )
        )

        window.alphaValue = 1.0

        // DON'T call orderFrontRegardless when hidden - it resets the position
        if !isHidden {
            window.orderFrontRegardless()
        }
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

    private func showIcon() {
        guard let window = floatingWindow else { return }

        // Get the screen where the window currently is
        let screen = window.screen ?? NSScreen.main
        guard let screen = screen else { return }

        // Only animate if currently hidden
        if isHidden {
            print("👈 Showing icon from the right...")
            isHidden = false

            let screenFrame = screen.visibleFrame
            let windowSize: CGFloat = 52
            let margin: CGFloat = 20
            let visibleX = screenFrame.maxX - windowSize - margin
            let y = screenFrame.minY + margin
            let targetFrame = NSRect(x: visibleX, y: y, width: windowSize, height: windowSize)

            print("   Moving from x=\(window.frame.origin.x) to x=\(visibleX)")

            // Use setFrame with animation (same as hideIconToRight)
            window.setFrame(targetFrame, display: true, animate: true)

            print("✅ Icon shown on screen. Final frame: \(window.frame)")
        } else {
            print("ℹ️ Icon already visible, no animation needed")
        }
    }

    @objc private func screenConfigurationChanged() {
        // Screen resolution, arrangement, or display settings changed
        // Reposition the window to stay in the correct location
        print("🖥️ Screen configuration changed, repositioning icon...")

        guard let window = floatingWindow else { return }

        // Get the screen where the window is (or main screen if none)
        let screen = window.screen ?? NSScreen.main
        guard let screen = screen else { return }

        let screenFrame = screen.visibleFrame
        let windowSize: CGFloat = 52
        let margin: CGFloat = 20

        if isHidden {
            // Keep it hidden off-screen at the new screen position
            let hiddenX = screenFrame.maxX + 10
            let y = screenFrame.minY + margin
            window.setFrameOrigin(NSPoint(x: hiddenX, y: y))
            print("   Repositioned (hidden): x=\(hiddenX), y=\(y)")
        } else {
            // Keep it visible at the new screen position
            let visibleX = screenFrame.maxX - windowSize - margin
            let y = screenFrame.minY + margin
            window.setFrameOrigin(NSPoint(x: visibleX, y: y))
            print("   Repositioned (visible): x=\(visibleX), y=\(y)")
        }
    }

    // MARK: - Animations
    
    @objc private func pulseIcon() {
        DispatchQueue.main.async { [weak self] in
            self?.pulseOnce()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.pulseOnce() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self?.pulseOnce() }
        }
    }
    
    private func pulseOnce() {
        guard let window = floatingWindow else { return }
        
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            window.animator().alphaValue = 0.3
        }, completionHandler: { [weak self] in
            guard let window = self?.floatingWindow else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                window.animator().alphaValue = 1.0
            })
        })
    }
    
    private func flashSuccess() {
        guard let window = floatingWindow else { return }
        
        // Quick green flash for success
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            window.animator().alphaValue = 0.5
        }, completionHandler: { [weak self] in
            guard let window = self?.floatingWindow else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                window.animator().alphaValue = 1.0
            })
        })
    }
    
    // MARK: - Tap Handling
    
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
        
        let isModelDownloaded = true
        let isModelDownloading = false
        let downloadProgress = 1.0
        
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
            onOpenHotkeySettings: { [weak self] in
                self?.handleOpenHotkeySettings()
            },
            onOpenCleanupSettings: { [weak self] in
                self?.handleOpenCleanupSettings()
            },
            onOpenPerformance: { [weak self] in
                self?.handleOpenPerformance()
            },
            onReportIssue: { [weak self] in
                self?.handleReportIssue()
            },
            onCheckForUpdates: {
                UpdaterManager.shared.checkForUpdates()
            },
            onDismiss: { [weak self] in
                self?.hidePopover()
            }
        )
        
        let popoverWidth: CGFloat = 280

        let hostingView = NSHostingView(rootView: popoverView)
        // Size to the content's natural height so the popover fits whatever
        // rows are present (the production build has an extra "Check for
        // Updates" row that the dev build hides).
        hostingView.frame.size.width = popoverWidth
        let popoverHeight = hostingView.fittingSize.height
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
            popoverY = floatingFrame.origin.y - popoverHeight - margin
            
            if popoverY < screenFrame.minY {
                popoverY = screenFrame.maxY - popoverHeight - margin
            }
        }
        
        window.setFrameOrigin(NSPoint(x: popoverX, y: popoverY))
        
        window.alphaValue = 0
        window.orderFrontRegardless()
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1.0
        }
        
        popoverWindow = window
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
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
        }, completionHandler: { [weak self] in
            self?.popoverWindow?.close()
            self?.popoverWindow = nil
        })
    }
    
    // MARK: - Actions
    
    private func handleDownloadModel() {
        hidePopover()
    }

    private func handleRemoveModel() {
        hidePopover()
    }
    
    private func handleOpenHotkeySettings() {
        hidePopover()
        showHotkeySettingsWindow()
    }

    private func handleOpenCleanupSettings() {
        hidePopover()
        showCleanupSettingsWindow()
    }

    private func handleOpenPerformance() {
        hidePopover()
        showPerformanceWindow()
    }

    private func handleReportIssue() {
        hidePopover()
        NotificationCenter.default.post(name: .openFeedbackReport, object: nil)
    }
    
    // MARK: - Hotkey Settings Window

    private func showHotkeySettingsWindow() {
        if let existing = hotkeyWindow {
            existing.close()
            hotkeyWindow = nil
        }

        let hotkeyView = HotkeySettingsView(onHotkeyChanged: {
            NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
        })

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        window.title = "Hotkey Settings"
        window.contentView = NSHostingView(rootView: hotkeyView)
        window.center()
        window.isReleasedWhenClosed = false

        hotkeyWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Cleanup Settings Window

    private func showCleanupSettingsWindow() {
        if let existing = cleanupSettingsWindow {
            existing.close()
            cleanupSettingsWindow = nil
        }

        let view = CleanupSettingsView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 320),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "AI Cleanup Settings"
        // Blend the title bar into the popover-style blurred content
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .clear
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false

        cleanupSettingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Performance Window

    private func showPerformanceWindow() {
        if let existing = performanceWindow {
            existing.close()
            performanceWindow = nil
        }

        let performanceView = PerformanceView()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Performance"
        window.contentView = NSHostingView(rootView: performanceView)
        window.center()
        window.isReleasedWhenClosed = false

        performanceWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Download Modal

    private var downloadModalWindow: NSWindow?

    func showDownloadModal() {
        guard let screen = NSScreen.main else { return }

        let modalWidth: CGFloat = 420
        let modalHeight: CGFloat = 280

        let screenFrame = screen.visibleFrame
        let xPos = screenFrame.midX - (modalWidth / 2)
        let yPos = screenFrame.midY - (modalHeight / 2)

        let window = NSPanel(
            contentRect: NSRect(x: xPos, y: yPos, width: modalWidth, height: modalHeight),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.level = .modalPanel
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        window.contentView = NSHostingView(
            rootView: DownloadModalView(onDismiss: { [weak self] in
                self?.downloadModalWindow?.close()
                self?.downloadModalWindow = nil
            })
        )

        self.downloadModalWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func cleanup() {
        NotificationCenter.default.removeObserver(self)
        DispatchQueue.main.async { [weak self] in
            self?.popoverWindow?.close()
            self?.popoverWindow = nil
            self?.hotkeyWindow?.close()
            self?.hotkeyWindow = nil
            self?.cleanupSettingsWindow?.close()
            self?.cleanupSettingsWindow = nil
            self?.performanceWindow?.close()
            self?.performanceWindow = nil
            self?.downloadModalWindow?.close()
            self?.downloadModalWindow = nil
            self?.floatingWindow?.orderOut(nil)
            self?.floatingWindow?.close()
            self?.floatingWindow = nil
            print("🧹 Floating window cleaned up")
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Floating Indicator View

struct FloatingIndicatorView: View {
    let isRecording: Bool
    let isTranscribing: Bool
    let isCommandMode: Bool
    let isDownloading: Bool
    let downloadProgress: Double
    let onTap: () -> Void
    
    @State private var pulseScale: CGFloat = 1.0
    @State private var isHovered = false
    
    var body: some View {
        Button(action: onTap) {
            ZStack {
                // Pulsing ring for recording/transcribing
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
                        .onDisappear {
                            pulseScale = 1.0
                        }
                }
                
                // Shadow
                Circle()
                    .fill(Color.black.opacity(0.08))
                    .frame(width: 44, height: 44)
                    .offset(y: 1)
                
                // Main circle
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
                
                // Recording/transcribing ring
                if isRecording || isTranscribing {
                    Circle()
                        .stroke(accentColor, lineWidth: 2)
                        .frame(width: 44, height: 44)
                }
                
                // Download progress ring
                if isDownloading {
                    Circle()
                        .trim(from: 0, to: downloadProgress)
                        .stroke(Color.blue, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .frame(width: 44, height: 44)
                        .rotationEffect(.degrees(-90))
                }
                
                // Icon
                if isDownloading {
                    VStack(spacing: 0) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.blue)
                        Text("\(Int(downloadProgress * 100))%")
                            .font(.system(size: 8, weight: .semibold, design: .rounded))
                            .foregroundStyle(.blue.opacity(0.8))
                    }
                    .allowsHitTesting(false)
                } else {
                    Image(systemName: iconName)
                        .font(.system(size: iconSize, weight: .medium))
                        .foregroundStyle(iconColor)
                        .symbolEffect(.bounce, value: isRecording)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: 52, height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(helpText)
    }
    
    private var iconName: String {
        // Show warning icon if permissions not granted
        if !SetupWindowController.shared.allPermissionsGranted {
            return "exclamationmark.triangle.fill"
        }
        
        // Command mode - bolt icon
        if isCommandMode && (isRecording || isTranscribing) {
            return "bolt.fill"
        }
        
        // Dictation mode - waveform
        if isRecording { return "waveform" }
        if isTranscribing { return "ellipsis" }
        
        // Idle
        return "waveform"
    }
    
    private var iconSize: CGFloat {
        if isCommandMode && (isRecording || isTranscribing) {
            return 16
        }
        return isRecording ? 16 : 14
    }
    
    private var iconColor: Color {
        // Show orange warning if permissions not granted
        if !SetupWindowController.shared.allPermissionsGranted {
            return .orange
        }
        
        // Command mode - purple
        if isCommandMode && (isRecording || isTranscribing) {
            return .purple
        }
        
        // Dictation mode - red when recording
        if isRecording { return .red }
        if isTranscribing { return .orange }
        
        // Idle
        return .primary.opacity(0.4)
    }
    
    private var accentColor: Color {
        if isCommandMode {
            return .purple
        }
        return isRecording ? .red : .orange
    }
    
    private var helpText: String {
        if isCommandMode {
            return "Airboard - Command Mode"
        }
        return "Airboard"
    }
}

// MARK: - Download Modal View

/// Shared download progress so the modal and the floating indicator stay in sync.
final class DownloadState: ObservableObject {
    static let shared = DownloadState()
    @Published var progress: Double = 0.0
    private init() {}
}

struct DownloadModalView: View {
    let onDismiss: () -> Void

    @ObservedObject private var downloadState = DownloadState.shared
    @State private var animateGradient = false

    private var isWarmingUp: Bool { downloadState.progress >= 0.999 }

    var body: some View {
        ZStack {
            // Background blur effect
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header with animated gradient — sized by its content, no clipping
                ZStack {
                    LinearGradient(
                        colors: [
                            Color.blue.opacity(0.8),
                            Color.purple.opacity(0.6)
                        ],
                        startPoint: animateGradient ? .topLeading : .bottomTrailing,
                        endPoint: animateGradient ? .bottomTrailing : .topLeading
                    )
                    .animation(
                        Animation.easeInOut(duration: 3.0).repeatForever(autoreverses: true),
                        value: animateGradient
                    )

                    VStack(spacing: 10) {
                        Image(systemName: "waveform.circle.fill")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)

                        Text(isWarmingUp ? "Almost Ready" : "Downloading Speech Model")
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                    }
                    .padding(.vertical, 20)
                }
                .fixedSize(horizontal: false, vertical: true)

                // Content area
                VStack(spacing: 16) {
                    Text("Airboard is completely private and works offline. The speech model is downloaded once to your Mac — after that, everything runs locally.")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(4)
                        .padding(.horizontal, 24)

                    // Live progress
                    VStack(spacing: 6) {
                        ProgressView(value: downloadState.progress)
                            .progressViewStyle(.linear)
                            .tint(.blue)
                            .padding(.horizontal, 32)

                        Text(isWarmingUp
                             ? "Preparing the model — the logo will pulse when ready"
                             : "\(Int(downloadState.progress * 100))% · ~630 MB, one-time download")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }

                    Button(action: onDismiss) {
                        Text("OK")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                            .frame(width: 100)
                            .padding(.vertical, 8)
                            .background(
                                LinearGradient(
                                    colors: [Color.blue, Color.blue.opacity(0.8)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 20)
                .padding(.horizontal, 20)
            }
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
        .onAppear {
            animateGradient = true
        }
    }
}

// MARK: - Visual Effect View

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

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
