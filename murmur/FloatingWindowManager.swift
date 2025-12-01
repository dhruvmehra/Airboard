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
    
    func showFloatingIndicator(isRecording: Bool, isTranscribing: Bool) {
        DispatchQueue.main.async {
            if self.floatingWindow == nil {
                self.createFloatingWindow()
            }
            
            if let window = self.floatingWindow {
                window.contentView = NSHostingView(
                    rootView: FloatingIndicatorView(
                        isRecording: isRecording,
                        isTranscribing: isTranscribing
                    )
                )
                window.orderFrontRegardless()
                window.animator().alphaValue = 1.0
                print("👁️ Indicator shown")
            }
        }
    }
    
    func hideFloatingIndicator() {
        DispatchQueue.main.async {
            self.floatingWindow?.animator().alphaValue = 0.0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.floatingWindow?.orderOut(nil)
                print("👁️ Indicator hidden")
            }
        }
    }
    
    private func createFloatingWindow() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 36, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.alphaValue = 0.0
        
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - 52
            let y = screenFrame.minY + 52
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
        
        floatingWindow = window
        print("✅ Floating window created")
    }
}

struct FloatingIndicatorView: View {
    let isRecording: Bool
    let isTranscribing: Bool
    
    @State private var breathe = false
    
    var body: some View {
        ZStack {
            // Single clean circle with vibrancy
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 36, height: 36)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                )
                .shadow(
                    color: statusColor.opacity(isRecording ? 0.4 : 0.2),
                    radius: isRecording ? 12 : 8,
                    x: 0,
                    y: 2
                )
            
            // Icon - clean and simple
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(statusColor)
                .opacity(isTranscribing ? 0.6 : 1.0)
        }
        .scaleEffect(breathe ? 1.08 : 1.0)
        .animation(
            isRecording ?
                .easeInOut(duration: 1.6).repeatForever(autoreverses: true) :
                .spring(response: 0.3, dampingFraction: 0.6),
            value: breathe
        )
        .onAppear {
            if isRecording {
                breathe = true
            }
        }
        .onChange(of: isRecording) { oldValue, newValue in
            breathe = newValue
        }
    }
    
    private var statusColor: Color {
        if isRecording {
            return Color(red: 1.0, green: 0.27, blue: 0.23)
        } else if isTranscribing {
            return Color(red: 1.0, green: 0.62, blue: 0.04)
        } else {
            return Color(red: 0.56, green: 0.56, blue: 0.58)
        }
    }
    
    private var iconName: String {
        if isRecording {
            return "mic.fill"
        } else if isTranscribing {
            return "waveform"
        } else {
            return "mic"
        }
    }
}
