//
//  FeedbackManager.swift
//  Airboard
//
//  Secure feedback system using Cloudflare Workers KV
//

import Foundation
import AppKit
import SwiftUI

class FeedbackManager {
    static let shared = FeedbackManager()
    
    // MARK: - Configuration
    // Replace this with your Cloudflare Worker URL after deployment
    private let feedbackEndpoint = "https://airboard-feedback.dhruv-d21.workers.dev"
    private var feedbackWindow: NSWindow?
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Show feedback dialog, then send and confirm in same window
    func reportIssue(
        transcribedText: String?,
        context: AppContext?
    ) {
        guard let text = transcribedText, !text.isEmpty else {
            showNoTranscriptionAlert()
            return
        }
        
        showFeedbackDialog(
            transcribedText: text,
            context: context
        )
    }
    
    // MARK: - UI
    
    private func showNoTranscriptionAlert() {
        let alert = NSAlert()
        alert.messageText = "No Recent Transcription"
        alert.informativeText = "Please dictate something first, then report an issue."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    
    private func showFeedbackDialog(
        transcribedText: String,
        context: AppContext?
    ) {
        // Close any existing window
        feedbackWindow?.close()
        feedbackWindow = nil
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        
        window.title = "Report Issue"
        window.center()
        window.isReleasedWhenClosed = false  // ← Changed to false
        
        // Store the window as instance variable
        feedbackWindow = window
        
        let view = FeedbackView(
            transcribedText: transcribedText,
            context: context,
            onSubmit: { [weak self] comment in
                self?.sendFeedback(
                    transcribedText: transcribedText,
                    comment: comment,
                    context: context
                )
            },
            onClose: { [weak self] in
                // Close safely with weak reference
                DispatchQueue.main.async {
                    self?.feedbackWindow?.close()
                    self?.feedbackWindow = nil
                }
            }
        )
        
        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    // MARK: - Backend Integration
    
    private func sendFeedback(
        transcribedText: String,
        comment: String?,
        context: AppContext?
    ) {
        Task {
            do {
                let deviceInfo = getDeviceInfo()
                
                let fullText = if let comment = comment, !comment.isEmpty {
                    "\(transcribedText)\n\nUser comment: \(comment)"
                } else {
                    transcribedText
                }
                
                let feedback = FeedbackPayload(
                    id: UUID().uuidString,
                    timestamp: ISO8601DateFormatter().string(from: Date()),
                    transcribedText: fullText,
                    expectedText: comment ?? "",
                    appContext: context?.appType.description ?? "unknown",
                    appName: context?.appName ?? "unknown",
                    osVersion: deviceInfo.osVersion,
                    macModel: deviceInfo.modelName,
                    appVersion: deviceInfo.appVersion,
                    wer: 0.0
                )
                
                try await sendToBackend(feedback: feedback)
                
                print("✅ Issue reported successfully")
                
            } catch {
                print("❌ Failed to report issue: \(error.localizedDescription)")
                
                saveFeedbackLocally(
                    transcribedText: transcribedText,
                    comment: comment,
                    context: context
                )
                
                await MainActor.run {
                    showErrorAlert()
                }
            }
        }
    }
    
    private func sendToBackend(feedback: FeedbackPayload) async throws {
        guard let url = URL(string: feedbackEndpoint) else {
            throw FeedbackError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(feedback)
        request.timeoutInterval = 10
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw FeedbackError.serverError
        }
    }
    
    // MARK: - Helpers
    
    private func getDeviceInfo() -> DeviceInfo {
        let processInfo = ProcessInfo.processInfo
        return DeviceInfo(
            osVersion: processInfo.operatingSystemVersionString,
            modelName: getModelName(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        )
    }
    
    private func getModelName() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }
    
    private func saveFeedbackLocally(
        transcribedText: String,
        comment: String?,
        context: AppContext?
    ) {
        let feedback = [
            "transcribedText": transcribedText,
            "comment": comment ?? "",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "context": context?.appType.description ?? "unknown"
        ]
        
        let logsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Airboard/Logs", isDirectory: true)
        
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        
        let logFile = logsDir.appendingPathComponent("feedback_\(Date().timeIntervalSince1970).json")
        
        if let jsonData = try? JSONSerialization.data(withJSONObject: feedback, options: .prettyPrinted) {
            try? jsonData.write(to: logFile)
            print("💾 Feedback saved locally: \(logFile.path)")
        }
    }
    
    private func showErrorAlert() {
        let alert = NSAlert()
        alert.messageText = "Network Error"
        alert.informativeText = "Your report was saved locally and will be sent when connection is available."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Data Models

struct FeedbackPayload: Codable {
    let id: String
    let timestamp: String
    let transcribedText: String
    let expectedText: String
    let appContext: String
    let appName: String
    let osVersion: String
    let macModel: String
    let appVersion: String
    let wer: Double
}

struct DeviceInfo {
    let osVersion: String
    let modelName: String
    let appVersion: String
}

extension AppType {
    var description: String {
        switch self {
        case .email: return "email"
        case .messaging: return "messaging"
        case .code: return "code"
        case .document: return "document"
        case .notes: return "notes"
        case .browser: return "browser"
        case .social: return "social"
        case .general: return "general"
        }
    }
}

enum FeedbackError: Error {
    case invalidURL
    case serverError
}
