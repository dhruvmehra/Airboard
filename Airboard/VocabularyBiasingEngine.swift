//
//  VocabularyBiasingEngine.swift
//
//  On-device acoustic vocabulary biasing: after Parakeet transcribes, a
//  CTC keyword spotter re-examines the audio for the user's memory terms
//  (glossary + extracted names) and a rescorer corrects the transcript
//  from acoustic evidence (NVIDIA CTC Word Spotter, arXiv:2406.07096, as
//  shipped in FluidAudio 0.15.5 — the exact pattern of FluidAudioCLI's
//  batch mode; the library doc's Quick Start is stale, do not follow it).
//
//  Contract: empty watch-list = completely inert (no download, no memory,
//  no rescore). Any failure -> nil (caller keeps Parakeet's raw text).
//

import Foundation
import AVFoundation
import FluidAudio

actor VocabularyBiasingEngine {
    static let shared = VocabularyBiasingEngine()

    /// Personal-dictation precision floor. FluidAudio's small-vocab default
    /// (minSimilarity 0.50, tuned on earnings-call jargon) over-fires on
    /// conversational speech — with a 1-term list it stamped a name over
    /// acoustically-adjacent words ("Inakshi" vs "and she…", field bug).
    /// Their own FDA benchmark shows tightening the gate collapses false
    /// positives at almost no recall cost. A correction must be
    /// acoustically CONVINCING: a missed correction is mild, a corrupted
    /// word is terrible.
    private static let similarityFloor: Float = 0.65

    private var vocab: CustomVocabularyContext?
    private var ctcModels: CtcModels?
    private var spotter: CtcKeywordSpotter?
    private var builtRevision: Int = -1
    private var downloadFailedThisLaunch = false

    private var rebuildInFlight = false

    /// Rescore a transcript against the memory watch-list. nil = leave the
    /// transcript alone (empty list, unavailable helper, or any failure).
    func rescore(text: String, tokenTimings: [TokenTiming], audioURL: URL) async -> String? {
        await rebuildIfNeeded()
        guard let vocab, let ctcModels, let spotter, !tokenTimings.isEmpty else { return nil }

        do {
            guard let samples = Self.loadSamples(from: audioURL) else { return nil }
            let spotResult = try await spotter.spotKeywordsWithLogProbs(
                audioSamples: samples, customVocabulary: vocab, minScore: nil)
            guard !spotResult.logProbs.isEmpty else { return nil }

            let vocabConfig = ContextBiasingConstants.rescorerConfig(forVocabSize: vocab.terms.count)
            let rescorer = try await VocabularyRescorer.create(
                spotter: spotter, vocabulary: vocab,
                config: .default,
                ctcModelDirectory: CtcModels.defaultCacheDirectory(for: ctcModels.variant))
            let out = rescorer.ctcTokenRescore(
                transcript: text, tokenTimings: tokenTimings,
                logProbs: spotResult.logProbs, frameDuration: spotResult.frameDuration,
                cbw: vocabConfig.cbw,
                marginSeconds: ContextBiasingConstants.defaultMarginSeconds,
                minSimilarity: max(vocabConfig.minSimilarity, Self.similarityFloor))
            if out.wasModified {
                print("🎯 Vocabulary biasing corrected: '\(text)' -> '\(out.text)'")
                return out.text
            }
            return nil
        } catch {
            print("⚠️ Vocabulary biasing skipped: \(error.localizedDescription)")
            return nil
        }
    }

    /// Rebuild the vocabulary when memory changed. Empty watch-list tears
    /// biasing down entirely (zero cost). First non-empty list triggers
    /// the one-time ~97.5MB CTC helper download (no progress API — an
    /// indeterminate toast announces start and completion).
    private func rebuildIfNeeded() async {
        let (revision, content) = await MainActor.run {
            (MemoryStore.shared.revision, MemoryBias.vocabFileContent(from: MemoryStore.shared.data))
        }
        guard revision != builtRevision else { return }

        guard let content else {
            vocab = nil; ctcModels = nil; spotter = nil
            builtRevision = revision
            return
        }
        guard !downloadFailedThisLaunch, !rebuildInFlight else { return }

        // First-ever activation needs a ~98MB download — NEVER make a
        // dictation wait on the network. Kick the build off in the
        // background and let this transcription go out unbiased; the
        // next one after the download completes gets biasing.
        let modelsCached = CtcModels.modelsExist(at: CtcModels.defaultCacheDirectory(for: .ctc110m))
        if !modelsCached {
            rebuildInFlight = true
            Task { [weak self] in
                await self?.buildVocabulary(revision: revision, content: content)
                await self?.clearRebuildFlag()
            }
            return
        }
        await buildVocabulary(revision: revision, content: content)
    }

    private func clearRebuildFlag() {
        rebuildInFlight = false
    }

    private func buildVocabulary(revision: Int, content: String) async {
        do {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.pype.airboard", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let vocabFile = dir.appendingPathComponent("bias-vocabulary.txt")
            try content.write(to: vocabFile, atomically: true, encoding: .utf8)

            let cacheDir = CtcModels.defaultCacheDirectory(for: .ctc110m)
            let needsDownload = !CtcModels.modelsExist(at: cacheDir)
            if needsDownload {
                print("📥 Downloading name-recognition helper (~98MB, one time)...")
                await MainActor.run {
                    FloatingWindowManager.shared.showToast("Downloading name recognition (98 MB, one time)…")
                }
            }
            let (loadedVocab, loadedModels) = try await CustomVocabularyContext.loadWithCtcTokens(
                from: vocabFile.path, ctcVariant: .ctc110m)
            vocab = loadedVocab
            ctcModels = loadedModels
            spotter = CtcKeywordSpotter(models: loadedModels, blankId: loadedModels.vocabulary.count)
            builtRevision = revision
            print("🎯 Vocabulary biasing active: \(loadedVocab.terms.count) terms")
            if needsDownload {
                await MainActor.run {
                    FloatingWindowManager.shared.showToast("Name recognition ready")
                }
            }
        } catch {
            print("⚠️ Vocabulary biasing unavailable: \(error.localizedDescription)")
            downloadFailedThisLaunch = true  // retry next launch, not every dictation
        }
    }

    /// 16kHz mono Float32 samples from the recorded WAV.
    private static func loadSamples(from url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: file.fileFormat.sampleRate,
                                   channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let channel = buffer.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
