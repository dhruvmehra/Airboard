import SwiftUI

struct ModelDownloadView: View {
    @ObservedObject var downloadManager = ModelDownloadManager.shared
    @State private var showingDeleteConfirmation = false
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            
            iconView
                .padding(.bottom, 16)
            
            Text(titleText)
                .font(.system(size: 24, weight: .semibold))
                .padding(.bottom, 4)
            
            Text(subtitleText)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.bottom, 24)
            
            actionView
            
            Spacer()
            Spacer()
        }
        .frame(width: 340, height: 300)
    }
    
    @ViewBuilder
    private var iconView: some View {
        if downloadManager.isDownloading {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.1), lineWidth: 5)
                    .frame(width: 60, height: 60)
                
                Circle()
                    .trim(from: 0, to: downloadManager.downloadProgress)
                    .stroke(.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .frame(width: 60, height: 60)
                    .rotationEffect(.degrees(-90))
                
                Text("\(Int(downloadManager.downloadProgress * 100))%")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(.blue)
            }
        } else {
            Image(systemName: iconName)
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(iconColor)
        }
    }
    
    @ViewBuilder
    private var actionView: some View {
        if downloadManager.isDownloading {
            Button("Cancel") {
                downloadManager.cancelDownload()
            }
            .foregroundColor(.secondary)
            
        } else if downloadManager.isModelReady {
            HStack(spacing: 10) {
                Button("Remove") {
                    showingDeleteConfirmation = true
                }
                .foregroundColor(.secondary)
                
                Button("Test") {
                    testModel()
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
            .confirmationDialog("Remove model?", isPresented: $showingDeleteConfirmation) {
                Button("Remove", role: .destructive) {
                    downloadManager.deleteModel()
                }
            }
            
        } else {
            Button {
                if downloadManager.downloadError != nil {
                    downloadManager.retryDownload()
                } else {
                    downloadManager.downloadModel()
                }
            } label: {
                Text(downloadManager.downloadError != nil ? "Retry" : "Download")
                    .fontWeight(.semibold)
                    .frame(width: 140, height: 40)
            }
            .buttonStyle(.borderedProminent)
        }
    }
    
    private var titleText: String {
        if downloadManager.isDownloading {
            return "Downloading"
        } else if downloadManager.isModelReady {
            return "Ready"
        } else if downloadManager.downloadError != nil {
            return "Failed"
        } else {
            return "AI Enhancements"
        }
    }
    
    private var subtitleText: String {
        if downloadManager.isDownloading {
            let mb = Int(downloadManager.downloadProgress * 1300)
            return "\(mb) of 1,300 MB"
        } else if downloadManager.isModelReady {
            return "AI is active"
        } else if downloadManager.downloadError != nil {
            return "Try again"
        } else {
            return "Better spacing & punctuation"
        }
    }
    
    private var iconName: String {
        if downloadManager.isModelReady {
            return "checkmark.circle.fill"
        } else if downloadManager.downloadError != nil {
            return "exclamationmark.triangle.fill"
        } else {
            return "sparkles"
        }
    }
    
    private var iconColor: LinearGradient {
        if downloadManager.isModelReady {
            return LinearGradient(colors: [.green, .green.opacity(0.7)], startPoint: .top, endPoint: .bottom)
        } else if downloadManager.downloadError != nil {
            return LinearGradient(colors: [.orange, .orange.opacity(0.7)], startPoint: .top, endPoint: .bottom)
        } else {
            return LinearGradient(colors: [.blue, .blue.opacity(0.7)], startPoint: .top, endPoint: .bottom)
        }
    }
    
    private func testModel() {
        Task {
            try? await LlamaService.shared.loadModel()
            let _ = try? await LlamaService.shared.cleanupText("test hello world")
        }
    }
}

#Preview {
    ModelDownloadView()
}
