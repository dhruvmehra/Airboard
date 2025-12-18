import Foundation
import Combine

/// Manages downloading and caching of the Llama model
class ModelDownloadManager: NSObject, ObservableObject {
    static let shared = ModelDownloadManager()
    
    // MARK: - Published Properties
    @Published var downloadProgress: Double = 0.0
    @Published var isDownloading: Bool = false
    @Published var downloadError: String? = nil
    @Published var isModelReady: Bool = false
    
    // MARK: - Properties
    private let modelURL = "https://huggingface.co/bartowski/gemma-2-2b-it-GGUF/resolve/main/gemma-2-2b-it-Q4_K_M.gguf"
    private let modelName = "gemma-2-2b-it-q4.gguf"
    private var downloadTask: URLSessionDownloadTask?
    private var retryCount = 0
    private let maxRetries = 3
    
    // Model storage directory
    private var modelDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let airboardDir = appSupport.appendingPathComponent("Airboard", isDirectory: true)
        let modelsDir = airboardDir.appendingPathComponent("Models", isDirectory: true)
        
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        return modelsDir
    }
    
    var modelPath: URL {
        return modelDirectory.appendingPathComponent(modelName)
    }
    
    // MARK: - Initialization
    override private init() {
        super.init()
        checkModelAvailability()
    }
    
    // MARK: - Public Methods
    
    /// Check if model is already downloaded
    func checkModelAvailability() {
        isModelReady = FileManager.default.fileExists(atPath: modelPath.path)
    }
    
    /// Start downloading the model
    func downloadModel() {
        guard !isDownloading else { return }
        
        // Check if already downloaded
        if isModelReady {
            print("✅ Model already downloaded")
            return
        }
        
        downloadError = nil
        isDownloading = true
        downloadProgress = 0.0
        
        print("📥 Starting model download...")
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300 // 5 minutes
        config.timeoutIntervalForResource = 3600 // 1 hour
        
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        
        guard let url = URL(string: modelURL) else {
            handleDownloadError("Invalid model URL")
            return
        }
        
        downloadTask = session.downloadTask(with: url)
        downloadTask?.resume()
    }
    
    /// Cancel ongoing download
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        
        DispatchQueue.main.async {
            self.isDownloading = false
            self.downloadProgress = 0.0
            self.downloadError = "Download cancelled"
        }
        
        print("❌ Download cancelled by user")
    }
    
    /// Retry failed download
    func retryDownload() {
        guard retryCount < maxRetries else {
            handleDownloadError("Maximum retry attempts reached. Please check your internet connection.")
            return
        }
        
        retryCount += 1
        print("🔄 Retrying download (attempt \(retryCount)/\(maxRetries))...")
        
        downloadError = nil
        downloadModel()
    }
    
    /// Delete downloaded model
    func deleteModel() {
        do {
            if FileManager.default.fileExists(atPath: modelPath.path) {
                try FileManager.default.removeItem(at: modelPath)
                print("🗑️ Model deleted successfully")
            }
            
            DispatchQueue.main.async {
                self.isModelReady = false
                self.downloadProgress = 0.0
            }
        } catch {
            print("❌ Error deleting model: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Private Methods
    
    private func handleDownloadError(_ message: String) {
        DispatchQueue.main.async {
            self.isDownloading = false
            self.downloadError = message
        }
        print("❌ Download error: \(message)")
    }
    
    private func handleDownloadSuccess() {
        retryCount = 0
        
        DispatchQueue.main.async {
            self.isDownloading = false
            self.isModelReady = true
            self.downloadProgress = 1.0
            self.downloadError = nil
        }
        
        print("✅ Model downloaded successfully!")
    }
}

// MARK: - URLSessionDownloadDelegate
extension ModelDownloadManager: URLSessionDownloadDelegate {
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            // Move downloaded file to permanent location
            if FileManager.default.fileExists(atPath: modelPath.path) {
                try FileManager.default.removeItem(at: modelPath)
            }
            
            try FileManager.default.moveItem(at: location, to: modelPath)
            
            handleDownloadSuccess()
            
        } catch {
            handleDownloadError("Failed to save model: \(error.localizedDescription)")
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        
        guard totalBytesExpectedToWrite > 0 else { return }
        
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let percentComplete = Int(progress * 100)
        
        DispatchQueue.main.async {
            self.downloadProgress = progress
        }
        
        // Log every 10%
        if percentComplete % 10 == 0 {
            let mbDownloaded = Double(totalBytesWritten) / 1_048_576
            let mbTotal = Double(totalBytesExpectedToWrite) / 1_048_576
            print("📊 Download progress: \(percentComplete)% (\(Int(mbDownloaded))MB / \(Int(mbTotal))MB)")
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error else { return }
        
        // Check if it was cancelled by user
        if (error as NSError).code == NSURLErrorCancelled {
            return
        }
        
        // Handle network errors with retry
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            if retryCount < maxRetries {
                print("⚠️ Network error, will retry...")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.retryDownload()
                }
                return
            }
        }
        
        handleDownloadError("Download failed: \(error.localizedDescription)")
    }
}
