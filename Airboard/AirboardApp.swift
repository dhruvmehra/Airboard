//
//  AirboardApp.swift
//
//  Created by Dhruv Mehra on 01/12/25.
//

import SwiftUI
import AVFoundation
import ApplicationServices

@main
struct AirboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings { EmptyView() }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotkeyManager = HotkeyManager()
    private lazy var coordinator = TranscriptionCoordinator.shared
    
    /// Route stdout+stderr to a log file instead of discarding them. The old
    /// version dup2'd stderr to /dev/null, which made every field problem
    /// undiagnosable — "check the logs" had no logs to check. The file is
    /// truncated on each launch so it never grows unbounded.
    private func redirectLogsToFile() {
        let logDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logPath = logDir.appendingPathComponent("Airboard.log").path

        let fd = open(logPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd != -1 {
            dup2(fd, STDOUT_FILENO)
            dup2(fd, STDERR_FILENO)
            close(fd)
            // Line-buffer stdout so prints land in the file promptly
            setvbuf(stdout, nil, _IOLBF, 0)
        }
        print("📓 Log started \(Date()) — \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.bundleIdentifier ?? "?"))")
    }

    /// The Whisper-based versions of Airboard cached a ~630MB model under
    /// ~/Documents/huggingface/. Nothing reads it after the Parakeet swap, so
    /// remove it. Cheap existence check → no-op on machines that never had it.
    private func cleanupLegacyWhisperModels() {
        let legacyDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")
        guard FileManager.default.fileExists(atPath: legacyDir.path) else { return }
        do {
            try FileManager.default.removeItem(at: legacyDir)
            print("🧹 Removed legacy Whisper model cache at \(legacyDir.path)")
        } catch {
            print("⚠️ Could not remove legacy Whisper cache: \(error.localizedDescription)")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 Airboard launched")
        redirectLogsToFile()
        cleanupLegacyWhisperModels()

        // Prevent multiple instances
        let runningInstances = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        if runningInstances.count > 1 {
            print("⚠️ Another instance running")
            NSApp.terminate(nil)
            return
        }

        UpdaterManager.shared.start()

        // Show in Dock (always visible)
        NSApp.setActivationPolicy(.regular)
        
        // Setup menu bar
        MenuBarManager.shared.setup()
        
        // Initialize coordinator (creates floating icon)
        Task { await coordinator.initialize() }
        
        // Show setup window if needed, then start hotkey monitoring
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            SetupWindowController.shared.startSetupIfNeeded {
                self?.startHotkeyMonitoring()
                MenuBarManager.shared.rebuildMenu()
                // Nudge the user toward dictation after long typing stretches
                TypingActivityMonitor.shared.start()
            }
        }
        
        // Listen for feedback report
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openFeedbackReport),
            name: .openFeedbackReport,
            object: nil
        )
        
        // Listen for hotkey changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotkeyDidChange),
            name: .hotkeyChanged,
            object: nil
        )
    }
    
    private func startHotkeyMonitoring() {
        hotkeyManager.startMonitoring(
            onDictationStart: { [weak self] in
                guard let self = self else { return }
                // Check if this is hands-free mode (double-tap)
                if self.hotkeyManager.isHandsFreeModeActive {
                    self.coordinator.startHandsFreeRecording()
                } else {
                    self.coordinator.startRecording()
                }
            },
            onCommandStart: { [weak self] in
                self?.coordinator.startCommandRecording()
            },
            onRelease: { [weak self] in
                guard let self = self else { return }
                // Check if we're stopping hands-free mode
                if self.coordinator.isHandsFreeMode {
                    self.coordinator.stopHandsFreeRecording()
                } else {
                    self.coordinator.stopRecording(mode: self.hotkeyManager.currentMode)
                }
            }
        )
    }
    
    @objc func hotkeyDidChange() {
        print("🔄 Hotkey changed, restarting monitoring")
        hotkeyManager.restartMonitoring(
            onDictationStart: { [weak self] in
                guard let self = self else { return }
                // Check if this is hands-free mode (double-tap)
                if self.hotkeyManager.isHandsFreeModeActive {
                    self.coordinator.startHandsFreeRecording()
                } else {
                    self.coordinator.startRecording()
                }
            },
            onCommandStart: { [weak self] in
                self?.coordinator.startCommandRecording()
            },
            onRelease: { [weak self] in
                guard let self = self else { return }
                // Check if we're stopping hands-free mode
                if self.coordinator.isHandsFreeMode {
                    self.coordinator.stopHandsFreeRecording()
                } else {
                    self.coordinator.stopRecording(mode: self.hotkeyManager.currentMode)
                }
            }
        )
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        print("👋 App terminating")
        hotkeyManager.stopMonitoring()
        FloatingWindowManager.shared.cleanup()
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Don't quit when setup window closes
        return false
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc func openFeedbackReport() {
        DispatchQueue.main.async {
            let coord = TranscriptionCoordinator.shared
            FeedbackManager.shared.reportIssue(
                transcribedText: coord.lastTranscribedText,
                context: coord.lastContext
            )
        }
    }
}
