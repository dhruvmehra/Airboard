//
//  MicCaptureEngine.swift
//
//  Capture core that records from a SPECIFIC input device (or the system
//  default when deviceUID is nil) to 16kHz mono Int16 WAV — the pipeline's
//  contract.
//
//  Built on AVCaptureSession, NOT AVAudioEngine. AVAudioEngine with a
//  kAudioOutputUnitProperty_CurrentDevice pin was the root cause of every
//  field failure this component has had: pinning the default device spawned
//  CADefaultDeviceAggregate ghosts and a HAL-mutex deadlock; pinning a
//  non-default device starved the render callbacks after ~0.2s (verified in
//  isolation, 2026-07-24: 0.2s of audio delivered in 3s wall time — while
//  AVCaptureSession pinned to the same device delivered all 3.0s).
//  AVCaptureSession treats device selection as a first-class input AND only
//  opens the device it was given — choosing the built-in mic never touches
//  a connected Bluetooth headset's mic, so playback never drops into the
//  muffled HFP profile.
//
//  The sample-buffer delegate runs on a private queue: all shared state is
//  lock-protected and this type must stay off the main actor.
//

import Foundation
import AVFoundation
import CoreMedia

nonisolated final class MicCaptureEngine: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    /// The output converts to the pipeline contract IN the session (macOS
    /// supports audioSettings on AVCaptureAudioDataOutput), so delegate
    /// buffers arrive ready to write — no AVAudioConverter stage.
    private static let outputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    private var session: AVCaptureSession?
    private let sampleQueue = DispatchQueue(label: "com.pype.airboard.mic-capture")

    private let stateLock = NSLock()
    private var file: AVAudioFile?
    private var _currentPowerDb: Float = -160
    private var isRunning = false

    /// Most recent input level (dB, approx). Poll from timers for pause detection.
    var currentPowerDb: Float {
        stateLock.lock(); defer { stateLock.unlock() }
        return _currentPowerDb
    }

    // There is deliberately NO warm-up/prepare() on this type: warming a
    // capture graph at launch opened the system-default INPUT device and
    // held it — with Bluetooth earphones connected, that forced the headset
    // into the HFP call profile (muffled output audio, mic flapping) the
    // moment the app started, even when the user's mic rule pointed
    // elsewhere.

    /// Begin capturing to fileURL. deviceUID nil = use the system default
    /// device. The UID is the CoreAudio device UID (identical to
    /// AVCaptureDevice.uniqueID on macOS — verified against live hardware).
    func start(deviceUID: String?, fileURL: URL) throws {
        stateLock.lock()
        let alreadyRunning = isRunning
        stateLock.unlock()
        guard !alreadyRunning else { return }

        // Resolve the requested device; fall back to the default mic when
        // no rule applies or the chosen device disappeared (spec behavior).
        var device: AVCaptureDevice?
        if let deviceUID {
            device = AVCaptureDevice(uniqueID: deviceUID)
            if device == nil {
                print("⚠️ Chosen mic '\(deviceUID)' not found; using system default")
            }
        }
        if device == nil { device = AVCaptureDevice.default(for: .audio) }
        guard let device else {
            throw NSError(domain: "MicCaptureEngine", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No input device available"])
        }

        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = Self.outputSettings
        output.setSampleBufferDelegate(self, queue: sampleQueue)

        let newSession = AVCaptureSession()
        guard newSession.canAddInput(input), newSession.canAddOutput(output) else {
            throw NSError(domain: "MicCaptureEngine", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Capture session rejected \(device.localizedName)"])
        }
        newSession.addInput(input)
        newSession.addOutput(output)

        let newFile = try AVAudioFile(forWriting: fileURL, settings: targetFormat.settings,
                                      commonFormat: .pcmFormatInt16, interleaved: true)

        stateLock.lock()
        file = newFile
        stateLock.unlock()

        // Synchronous; the session is delivering buffers when this returns.
        newSession.startRunning()

        session = newSession
        stateLock.lock()
        isRunning = true
        stateLock.unlock()
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate (private queue)

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                         frameCapacity: AVAudioFrameCount(frames)) else { return }
        pcm.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames),
            into: pcm.mutableAudioBufferList)
        guard status == noErr else { return }

        // Input level (RMS) for pause detection.
        var powerDb: Float = -160
        if let data = pcm.int16ChannelData?[0] {
            var sum: Float = 0
            for i in 0..<frames {
                let s = Float(data[i]) / Float(Int16.max)
                sum += s * s
            }
            let rms = frames > 0 ? sqrt(sum / Float(frames)) : 0
            powerDb = 20 * log10(max(rms, 1e-8))
        }

        stateLock.lock()
        _currentPowerDb = powerDb
        try? file?.write(from: pcm)
        stateLock.unlock()
    }

    /// Swap output files mid-capture (hands-free chunk rotation).
    /// Returns the finished file's URL. Capture continues without a gap.
    func rotate(to newURL: URL) -> URL? {
        let newFile = try? AVAudioFile(forWriting: newURL, settings: targetFormat.settings,
                                        commonFormat: .pcmFormatInt16, interleaved: true)
        guard let newFile else {
            print("❌ Chunk rotation failed: could not open \(newURL.lastPathComponent); continuing current chunk")
            return nil
        }

        stateLock.lock()
        let oldFile = file
        file = newFile
        stateLock.unlock()

        let finished = oldFile?.url
        // oldFile deallocates here, finalizing the WAV header OFF the delegate's lock.
        return finished
    }

    /// Stop capturing. Returns the final file's URL.
    func stop() -> URL? {
        stateLock.lock()
        let running = isRunning
        stateLock.unlock()
        guard running else { return nil }

        session?.stopRunning()
        session = nil

        stateLock.lock()
        let finished = file?.url
        file = nil
        isRunning = false
        _currentPowerDb = -160
        stateLock.unlock()

        return finished
    }
}
