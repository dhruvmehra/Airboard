//
//  MicCaptureEngine.swift
//
//  Capture core that records from a SPECIFIC input device (or the system
//  default when deviceID is nil) to 16kHz mono Int16 WAV — the pipeline's
//  contract. AVAudioRecorder cannot select a device; this engine can.
//  The tap runs on a realtime audio thread: all shared state is
//  lock-protected and this type must stay off the main actor.
//

import Foundation
import AVFoundation
import CoreAudio

nonisolated final class MicCaptureEngine {

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    private let stateLock = NSLock()
    private var file: AVAudioFile?
    private var _currentPowerDb: Float = -160
    private var isRunning = false

    /// Most recent input level (dB, approx). Poll from timers for pause detection.
    var currentPowerDb: Float {
        stateLock.lock(); defer { stateLock.unlock() }
        return _currentPowerDb
    }

    /// Warm the graph so start() is fast at hotkey time.
    func prepare() {
        _ = engine.inputNode
        engine.prepare()
    }

    /// Begin capturing to fileURL. deviceID nil = follow the system default.
    func start(deviceID: AudioDeviceID?, fileURL: URL) throws {
        stateLock.lock()
        let alreadyRunning = isRunning
        stateLock.unlock()
        guard !alreadyRunning else { return }

        let inputNode = engine.inputNode

        if let deviceID, let audioUnit = inputNode.audioUnit {
            var device = deviceID
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &device,
                UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr {
                // Fall back silently to the default device (spec behavior).
                print("⚠️ Could not pin input device (status \(status)); using system default")
            }
        }

        let hwFormat = inputNode.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw NSError(domain: "MicCaptureEngine", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Input device has no valid format"])
        }
        let newConverter = AVAudioConverter(from: hwFormat, to: targetFormat)
        let newFile = try AVAudioFile(forWriting: fileURL, settings: targetFormat.settings,
                                      commonFormat: .pcmFormatInt16, interleaved: true)

        stateLock.lock()
        converter = newConverter
        file = newFile
        stateLock.unlock()

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }

        try engine.start()

        stateLock.lock()
        isRunning = true
        stateLock.unlock()
    }

    private func handle(buffer: AVAudioPCMBuffer) {
        // Input level (RMS of the raw buffer) for pause detection.
        var powerDb: Float = -160
        if let data = buffer.floatChannelData?[0] {
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += data[i] * data[i] }
            let rms = n > 0 ? sqrt(sum / Float(n)) : 0
            powerDb = 20 * log10(max(rms, 1e-8))
        }

        stateLock.lock()
        _currentPowerDb = powerDb
        let converter = self.converter
        stateLock.unlock()

        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var fed = false
        var convError: NSError?
        converter.convert(to: out, error: &convError) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if convError != nil { return }

        stateLock.lock()
        try? file?.write(from: out)
        stateLock.unlock()
    }

    /// Swap output files mid-capture (hands-free chunk rotation).
    /// Returns the finished file's URL. Capture continues without a gap.
    func rotate(to newURL: URL) -> URL? {
        stateLock.lock(); defer { stateLock.unlock() }
        let finished = file?.url
        file = nil  // AVAudioFile finalizes on dealloc
        file = try? AVAudioFile(forWriting: newURL, settings: targetFormat.settings,
                                commonFormat: .pcmFormatInt16, interleaved: true)
        return finished
    }

    /// Stop capturing. Returns the final file's URL.
    func stop() -> URL? {
        stateLock.lock()
        let running = isRunning
        stateLock.unlock()
        guard running else { return nil }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        stateLock.lock()
        let finished = file?.url
        file = nil
        converter = nil
        isRunning = false
        _currentPowerDb = -160
        stateLock.unlock()
        return finished
    }
}
