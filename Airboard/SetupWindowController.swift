//
//  SetupWindowController.swift
//  Airboard
//
//  Apple-style setup window
//

import AppKit
import AVFoundation
import ApplicationServices

class SetupWindowController: NSObject, NSWindowDelegate {
    
    static let shared = SetupWindowController()
    
    private var window: NSWindow?
    private var onComplete: (() -> Void)?
    private var micStatusView: NSView?
    private var accStatusView: NSView?
    private var actionButton: NSButton?
    private var permissionCheckTimer: Timer?
    
    private let hasCompletedSetupKey = "hasCompletedSetup"
    
    var hasCompletedSetup: Bool {
        get { UserDefaults.standard.bool(forKey: hasCompletedSetupKey) }
        set { UserDefaults.standard.set(newValue, forKey: hasCompletedSetupKey) }
    }
    
    var isMicrophoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
    
    var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }
    
    var allPermissionsGranted: Bool {
        isMicrophoneGranted && isAccessibilityGranted
    }
    
    // MARK: - Start Setup
    
    func startSetupIfNeeded(completion: @escaping () -> Void) {
        self.onComplete = completion
        
        print("📋 Setup check: hasCompletedSetup=\(hasCompletedSetup), allPermissionsGranted=\(allPermissionsGranted)")
        
        if !hasCompletedSetup || !allPermissionsGranted {
            showSetupWindow()
        } else {
            completion()
        }
    }
    
    func showPermissionSetup() {
        showSetupWindow()
    }
    
    // MARK: - Window
    
    private func showSetupWindow() {
        window?.close()
        
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        newWindow.titlebarAppearsTransparent = true
        newWindow.titleVisibility = .hidden
        newWindow.backgroundColor = NSColor.windowBackgroundColor
        newWindow.delegate = self
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        newWindow.isMovableByWindowBackground = true
        
        setupContent(in: newWindow)
        
        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        startPermissionCheck()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }
    
    private func setupContent(in window: NSWindow) {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 400))
        
        // App Icon
        let iconView = NSImageView(frame: NSRect(x: 190, y: 290, width: 100, height: 100))
        if let appIcon = NSImage(named: NSImage.applicationIconName) {
            iconView.image = appIcon
        } else {
            iconView.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: nil)
            iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 64, weight: .medium)
            iconView.contentTintColor = NSColor.systemBlue
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        container.addSubview(iconView)
        
        // Title
        let titleLabel = NSTextField(labelWithString: "Welcome to Airboard")
        titleLabel.frame = NSRect(x: 0, y: 250, width: 480, height: 32)
        titleLabel.alignment = .center
        titleLabel.font = NSFont.systemFont(ofSize: 26, weight: .bold)
        titleLabel.textColor = NSColor.labelColor
        container.addSubview(titleLabel)
        
        // Subtitle
        let subtitleLabel = NSTextField(labelWithString: "Grant permissions to get started")
        subtitleLabel.frame = NSRect(x: 0, y: 222, width: 480, height: 20)
        subtitleLabel.alignment = .center
        subtitleLabel.font = NSFont.systemFont(ofSize: 13)
        subtitleLabel.textColor = NSColor.secondaryLabelColor
        container.addSubview(subtitleLabel)
        
        // Permission cards container
        let cardsContainer = NSView(frame: NSRect(x: 40, y: 95, width: 400, height: 115))
        container.addSubview(cardsContainer)
        
        // Microphone card
        let micCard = createPermissionCard(
            icon: "mic.fill",
            title: "Microphone",
            subtitle: "To hear your voice",
            isGranted: isMicrophoneGranted,
            yPosition: 60
        )
        micStatusView = micCard
        cardsContainer.addSubview(micCard)
        
        // Accessibility card
        let accCard = createPermissionCard(
            icon: "keyboard",
            title: "Accessibility",
            subtitle: "To detect keys & type text",
            isGranted: isAccessibilityGranted,
            yPosition: 0
        )
        accStatusView = accCard
        cardsContainer.addSubview(accCard)
        
        // Action Button
        let button = NSButton(title: "Continue", target: self, action: #selector(actionButtonTapped))
        button.frame = NSRect(x: 165, y: 35, width: 150, height: 44)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.keyEquivalent = "\r"
        button.contentTintColor = .white
        actionButton = button
        styleButton(button)
        container.addSubview(button)
        
        window.contentView = container
        updateUI()
    }
    
    private func createPermissionCard(icon: String, title: String, subtitle: String, isGranted: Bool, yPosition: CGFloat) -> NSView {
        let card = NSView(frame: NSRect(x: 0, y: yPosition, width: 400, height: 50))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.layer?.cornerRadius = 10
        
        // Icon background
        let iconBg = NSView(frame: NSRect(x: 12, y: 9, width: 32, height: 32))
        iconBg.wantsLayer = true
        iconBg.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.1).cgColor
        iconBg.layer?.cornerRadius = 8
        card.addSubview(iconBg)
        
        // Icon
        let iconView = NSImageView(frame: NSRect(x: 18, y: 15, width: 20, height: 20))
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        iconView.contentTintColor = NSColor.systemBlue
        card.addSubview(iconView)
        
        // Title
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.frame = NSRect(x: 56, y: 26, width: 200, height: 18)
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = NSColor.labelColor
        card.addSubview(titleLabel)
        
        // Subtitle
        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.frame = NSRect(x: 56, y: 8, width: 200, height: 16)
        subtitleLabel.font = NSFont.systemFont(ofSize: 12)
        subtitleLabel.textColor = NSColor.secondaryLabelColor
        card.addSubview(subtitleLabel)
        
        // Status indicator
        let statusView = NSImageView(frame: NSRect(x: 356, y: 13, width: 24, height: 24))
        statusView.tag = 100 // Tag to find it later
        updateStatusIndicator(statusView, isGranted: isGranted)
        card.addSubview(statusView)
        
        return card
    }
    
    private func updateStatusIndicator(_ imageView: NSImageView, isGranted: Bool) {
        if isGranted {
            imageView.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
            imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
            imageView.contentTintColor = NSColor.systemGreen
        } else {
            imageView.image = NSImage(systemSymbolName: "circle", accessibilityDescription: nil)
            imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
            imageView.contentTintColor = NSColor.tertiaryLabelColor
        }
    }
    
    private func styleButton(_ button: NSButton) {
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.systemBlue.cgColor
        button.layer?.cornerRadius = 10
        button.attributedTitle = NSAttributedString(
            string: button.title,
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold)
            ]
        )
    }
    
    private func updateButtonTitle(_ title: String) {
        guard let button = actionButton else { return }
        button.title = title
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold)
            ]
        )
    }
    
    @objc private func actionButtonTapped() {
        if allPermissionsGranted {
            completeSetup()
        } else if !isMicrophoneGranted {
            requestMicrophone()
        } else if !isAccessibilityGranted {
            openAccessibilitySettings()
        }
    }
    
    private func requestMicrophone() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateUI()
                    if self?.isMicrophoneGranted == true && self?.isAccessibilityGranted == false {
                        self?.openAccessibilitySettings()
                    }
                }
            }
        } else if status == .denied || status == .restricted {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }
    
    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    
    @objc private func appDidBecomeActive() {
        updateUI()
    }
    
    private func startPermissionCheck() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateUI()
        }
    }
    
    private func updateUI() {
        // Update mic status
        if let micCard = micStatusView,
           let statusView = micCard.viewWithTag(100) as? NSImageView {
            updateStatusIndicator(statusView, isGranted: isMicrophoneGranted)
        }
        
        // Update accessibility status
        if let accCard = accStatusView,
           let statusView = accCard.viewWithTag(100) as? NSImageView {
            updateStatusIndicator(statusView, isGranted: isAccessibilityGranted)
        }
        
        // Update button
        if allPermissionsGranted {
            updateButtonTitle("Get Started")
        } else if isMicrophoneGranted {
            updateButtonTitle("Enable Access")
        } else {
            updateButtonTitle("Enable Microphone")
        }
    }
    
    private func completeSetup() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
        NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: nil)
        hasCompletedSetup = true
        window?.close()
        window = nil
        NotificationCenter.default.post(name: .pulseFloatingIcon, object: nil)
        onComplete?()
    }
    
    // MARK: - Window Delegate
    
    func windowWillClose(_ notification: Notification) {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
        NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: nil)
        if !hasCompletedSetup {
            hasCompletedSetup = true
        }
        onComplete?()
    }
}
