//
//  ParakeetTranscriptionService.swift
//
//  Local speech-to-text using Parakeet TDT 0.6B v3 via FluidAudio (CoreML/ANE)
//

import Foundation
import Combine
import FluidAudio

class ParakeetTranscriptionService: ObservableObject {
    @Published var transcription: String = ""
    @Published var isTranscribing: Bool = false
    @Published var error: String?
    @Published var isDownloadingModel: Bool = false
    @Published var downloadProgress: Double = 0.0
    /// True only once models are downloaded, loaded AND warmed up — safe to transcribe.
    @Published var isModelReady: Bool = false

    private var asrManager: AsrManager?
    private var initializationTask: Task<Void, Never>?
    private var isRetrying = false

    /// Parakeet variant to load. v3 = multilingual (25 languages); switch to .v2
    /// for the English-only bundle (marginally better English recall).
    static let modelVersion = AsrModelVersion.v3

    init() {
        initializationTask = Task {
            await initializeParakeet()
        }
    }

    /// Waits for initialization; retries once if a previous attempt failed
    /// (e.g. no internet on first run), so a failed init doesn't require an
    /// app restart.
    ///
    /// Single-flight: if multiple callers race in here after a failed init
    /// (e.g. the hands-free chunk path spawns one Task per chunk), only the
    /// first spawns a retry; the rest await that same in-flight task instead
    /// of each kicking off their own ~1GB download into the same cache dir.
    func ensureModelReady() async {
        await initializationTask?.value
        if !isModelReady {
            if let existing = initializationTask, !existing.isCancelled, isRetrying {
                await existing.value
                return
            }
            isRetrying = true
            let retry = Task {
                await initializeParakeet()
            }
            initializationTask = retry
            await retry.value
            isRetrying = false
        }
    }

    private func initializeParakeet() async {
        do {
            print("🔄 Initializing Parakeet (FluidAudio)...")

            let cacheDir = AsrModels.defaultCacheDirectory(for: Self.modelVersion)
            let isCached = AsrModels.modelsExist(at: cacheDir, version: Self.modelVersion)

            if isCached {
                print("✅ Models found in cache, loading...")
            } else {
                print("📥 Models not cached, downloading (first run only)...")
                isDownloadingModel = true
                downloadProgress = 0.0
            }

            let models = try await AsrModels.downloadAndLoad(
                version: Self.modelVersion,
                progressHandler: { [weak self] progress in
                    Task { @MainActor in
                        guard let self = self, self.isDownloadingModel else { return }
                        self.downloadProgress = progress.fractionCompleted
                    }
                }
            )

            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            asrManager = manager

            downloadProgress = 1.0
            print("✅ Parakeet models loaded (cache: \(cacheDir.path))")

            // Keep the "getting ready" state visible through warm-up — the first
            // inference pays CoreML compile/ANE load costs, and transcribing
            // before it finishes would silently block (stuck-orange bug).
            await warmUpModel()

            isModelReady = true
            isDownloadingModel = false
            error = nil

            print("🎉 Ready to transcribe!")
        } catch {
            print("❌ Failed to initialize Parakeet: \(error.localizedDescription)")
            self.error = "Failed to initialize speech model: \(error.localizedDescription)"
            isDownloadingModel = false
            downloadProgress = 0.0
        }
    }

    private func warmUpModel() async {
        guard let asrManager = asrManager else { return }
        print("🔥 Warming up model with silent audio...")
        let silence = [Float](repeating: 0.0, count: 16_000) // 1s @ 16kHz
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        _ = try? await asrManager.transcribe(silence, decoderState: &decoderState)
        print("✅ Warmup complete")
    }

    func transcribe(audioURL: URL) async {
        let startTime = Date()

        isTranscribing = true
        error = nil
        transcription = ""

        if let attributes = try? FileManager.default.attributesOfItem(atPath: audioURL.path),
           let fileSize = attributes[.size] as? Int64 {
            print("📊 Audio: \(String(format: "%.1f", Double(fileSize) / 1024.0))KB")
            if fileSize < 1000 {
                print("⚠️ File too small")
                self.error = "Recording too short"
                isTranscribing = false
                deleteAudioFile(at: audioURL)
                return
            }
        }

        await ensureModelReady()

        guard let asrManager = asrManager, isModelReady else {
            self.error = "Speech model not ready"
            isTranscribing = false
            deleteAudioFile(at: audioURL)
            return
        }

        do {
            print("🌐 Transcribing...")
            var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
            let result = try await asrManager.transcribe(audioURL, decoderState: &decoderState)

            let duration = Date().timeIntervalSince(startTime) * 1000
            let transcribedText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

            print("📝 Raw Parakeet output: '\(transcribedText)' (confidence: \(result.confidence))")

            if transcribedText.isEmpty {
                self.error = "No speech detected"
                isTranscribing = false
                deleteAudioFile(at: audioURL)
                return
            }

            transcription = transcribedText

            PerformanceMonitor.shared.finalizeSession()
            isTranscribing = false

            print("✅ Done: \(transcribedText)")
            print("⏱️ \(Int(duration))ms")

            deleteAudioFile(at: audioURL)
        } catch {
            let duration = Date().timeIntervalSince(startTime) * 1000
            self.error = error.localizedDescription
            isTranscribing = false

            print("❌ Failed: \(error.localizedDescription)")
            print("⏱️ \(Int(duration))ms")

            deleteAudioFile(at: audioURL)
        }
    }

    private func deleteAudioFile(at url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
            print("🗑️ Deleted: \(url.lastPathComponent)")
        } catch {
            print("⚠️ Delete failed")
        }
    }
}
