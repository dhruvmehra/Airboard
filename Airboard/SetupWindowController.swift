//
//  SetupWindowController.swift
//  Airboard
//
//  Hosts the guided onboarding flow (OnboardingFlow.swift) and owns the
//  battle-tested permission logic the flow's steps call into. Shown only
//  when setup is incomplete or a permission is missing — existing users
//  with granted permissions never see it.
//

import AppKit
import SwiftUI
import AVFoundation
import ApplicationServices

class SetupWindowController: NSObject, NSWindowDelegate {

    static let shared = SetupWindowController()

    private var window: NSWindow?
    private var onComplete: (() -> Void)?

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

        if !hasCompletedSetup {
            showOnboarding(startingAt: .welcome)
        } else if !allPermissionsGranted {
            // Returning user with a revoked permission: jump straight to
            // the relevant permission step, no welcome tour.
            showOnboarding(startingAt: isMicrophoneGranted ? .accessibility : .microphone)
        } else {
            completion()
        }
    }

    func showPermissionSetup() {
        // Already presenting (e.g. Try It's insertion failed because
        // Accessibility was skipped): the onboarding window IS the
        // permission UI — surface it instead of rebuilding mid-flow.
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        showOnboarding(startingAt: isMicrophoneGranted ? .accessibility : .microphone)
    }

    // MARK: - Window

    private func showOnboarding(startingAt step: OnboardingFlow.Step) {
        // Detach the delegate before replacing the window: close() calls
        // windowWillClose synchronously, which would consume onComplete and
        // force-mark setup complete mid-swap.
        window?.delegate = nil
        window?.close()

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newWindow.titlebarAppearsTransparent = true
        newWindow.titleVisibility = .hidden
        // Opaque DS surface — never .clear (the Sonoma click-through lesson).
        newWindow.backgroundColor = .dsSurfaceWindow
        newWindow.isMovableByWindowBackground = true
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self
        newWindow.contentView = NSHostingView(
            rootView: OnboardingFlow(initialStep: step) { [weak self] in
                self?.finishSetup()
            }
        )
        newWindow.center()

        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Permission actions (reused by OnboardingFlow's steps)

    func requestMicrophoneAccess() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        } else if status == .denied || status == .restricted {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Completion (finish and skip share this wiring)

    private func finishSetup() {
        hasCompletedSetup = true
        let completion = onComplete
        onComplete = nil
        // Forces SwiftUI teardown/onDisappear — close() alone doesn't
        // guarantee it, and a leaked local key monitor from TryItStep would
        // keep driving the real recording pipeline whenever an Airboard
        // window is key.
        window?.contentView = nil
        window?.close()
        window = nil
        NotificationCenter.default.post(name: .pulseFloatingIcon, object: nil)
        completion?()
    }

    // MARK: - Window Delegate

    func windowWillClose(_ notification: Notification) {
        // Closing the window = skipping: same post-setup wiring as finishing.
        if !hasCompletedSetup { hasCompletedSetup = true }
        let completion = onComplete
        onComplete = nil
        // Forces SwiftUI teardown/onDisappear for the native red-X path too.
        window?.contentView = nil
        window = nil
        completion?()
    }
}
