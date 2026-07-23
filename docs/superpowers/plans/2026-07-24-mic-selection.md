# Microphone Selection with Per-Device Memory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user pick which mic Airboard records from, remembered per connected hardware (e.g. "when these earphones are connected, use the MacBook mic"), escaping the Bluetooth-mic quality trap.

**Architecture:** `MicDeviceManager` (new) enumerates input devices via CoreAudio, stores per-external-device rules in UserDefaults, and resolves which device a recording should use. `MicCaptureEngine` (new) is an AVAudioEngine wrapper that records from a *specific* device (AVAudioRecorder cannot) to the same 16kHz mono Int16 WAVs the pipeline expects, with mid-capture file rotation and an input-level readout. Both recorders swap their capture internals onto it; their public interfaces, callbacks, chunk policy, and normalization stay identical, so `TranscriptionCoordinator` is untouched. The popover gains a "Microphone" row with a dropdown.

**Tech Stack:** Swift 5 mode with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, AVFoundation (AVAudioEngine/AVAudioConverter/AVAudioFile), CoreAudio (device enumeration/listener), SwiftUI. No new SPM dependencies.

**Spec:** `docs/superpowers/specs/2026-07-24-mic-selection-design.md`

## Global Constraints

- Repo root `/Users/dhruvmehra/Desktop/proj/Airboard/Airboard`; all paths relative; commands run from it.
- Output format contract: recordings are 16kHz, mono, 16-bit LPCM WAV — identical to today. `TranscriptionCoordinator` must not change.
- Rule model (spec, verbatim scenarios): no rule → system default (first-time earphones = earphones mic); picking a mic while ≥1 external input device is connected stores the rule for the connected external device(s); resolve picks the most-recently-connected external that has a rule; chosen-but-absent mic → silent fallback to system default, rule kept.
- UserDefaults key: `micRuleByDevice` (`[String: String]`, externalDeviceUID → chosenMicUID).
- `deviceID: nil` in the capture engine means "do not pin" — the HAL unit follows the system default, exactly today's behavior.
- New `.swift` files under `Airboard/` are auto-included (filesystem-synchronized group).
- MainActor default isolation: the audio tap runs on a realtime thread — `MicCaptureEngine` must be `nonisolated` (or equivalent) so the tap compiles without actor hops; its shared state is lock-protected. If the compiler rejects a construct, adapt minimally but the tap must never hop to the main actor.
- No XCTest target; per-task verification = `xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug -derivedDataPath ./build/DerivedData build 2>&1 | tail -5` → `** BUILD SUCCEEDED **`, plus the scratch checks specified. Scratch mic capture may be blocked by TCC in the agent shell — the fallback in Task 2 Step 3 is explicit; audible verification happens in the app (Task 7 + user).
- Commit after every task with the exact message given. Do NOT run `./build_release.sh`.

---

### Task 1: MicDeviceManager

**Files:**
- Create: `Airboard/MicDeviceManager.swift`

**Interfaces:**
- Produces (used by Tasks 3–5):
  - `struct MicDevice: Identifiable, Equatable { let id: AudioDeviceID; let uid: String; let name: String; let isExternal: Bool }`
  - `MicDeviceManager.shared`
  - `@Published private(set) var inputDevices: [MicDevice]`
  - `func selectMic(uid: String)`
  - `func resolveActiveDeviceID() -> AudioDeviceID?`  (nil = don't pin / system default)
  - `var resolvedSelectionUID: String?` (nil = system default is in effect)
  - `var activeMicName: String`
  - `func refreshDevices()`

- [ ] **Step 1: Write the file**

Create `Airboard/MicDeviceManager.swift` with exactly:

```swift
//
//  MicDeviceManager.swift
//
//  Enumerates audio INPUT devices and remembers the user's mic choice per
//  connected external device ("when these earphones are present, use the
//  MacBook mic"). No rule -> system default, exactly today's behavior.
//  See docs/superpowers/specs/2026-07-24-mic-selection-design.md
//

import Foundation
import CoreAudio
import Combine

struct MicDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isExternal: Bool
}

final class MicDeviceManager: ObservableObject {
    static let shared = MicDeviceManager()

    static let rulesKey = "micRuleByDevice"

    @Published private(set) var inputDevices: [MicDevice] = []

    /// First time each UID was seen this app run — "most recently connected".
    private var connectedAt: [String: Date] = [:]

    private var rules: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Self.rulesKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.rulesKey) }
    }

    private init() {
        refreshDevices()
        installDeviceListListener()
    }

    // MARK: - Rules

    /// The user picked `uid` for the CURRENT hardware situation: store the
    /// rule for every external input device present. Built-in-only situation
    /// stores nothing (there is nothing to key by, and only one mic anyway).
    func selectMic(uid: String) {
        let externals = inputDevices.filter(\.isExternal)
        guard !externals.isEmpty else { return }
        var r = rules
        for ext in externals { r[ext.uid] = uid }
        rules = r
        objectWillChange.send()
        print("🎙️ Mic rule saved: use '\(uid)' while \(externals.map(\.name)) connected")
    }

    /// Which device should this recording use? nil = don't pin (follow the
    /// system default — no rule applies, or the chosen device is absent).
    func resolveActiveDeviceID() -> AudioDeviceID? {
        guard let uid = resolvedSelectionUID else { return nil }
        return inputDevices.first(where: { $0.uid == uid })?.id
    }

    /// The UID the current rules resolve to, or nil for system default.
    var resolvedSelectionUID: String? {
        let externalsByRecency = inputDevices
            .filter(\.isExternal)
            .sorted { a, b in
                let da = connectedAt[a.uid] ?? .distantPast
                let db = connectedAt[b.uid] ?? .distantPast
                if da != db { return da > db }
                return a.uid > b.uid
            }
        for ext in externalsByRecency {
            if let chosen = rules[ext.uid],
               inputDevices.contains(where: { $0.uid == chosen }) {
                return chosen
            }
        }
        return nil
    }

    /// Display name for the popover subtitle.
    var activeMicName: String {
        if let uid = resolvedSelectionUID,
           let device = inputDevices.first(where: { $0.uid == uid }) {
            return device.name
        }
        if let defaultID = Self.systemDefaultInputDeviceID(),
           let device = inputDevices.first(where: { $0.id == defaultID }) {
            return "\(device.name) (system default)"
        }
        return "System default"
    }

    // MARK: - CoreAudio enumeration

    func refreshDevices() {
        var found: [MicDevice] = []
        for id in Self.allDeviceIDs() where Self.inputChannelCount(id) > 0 {
            guard let uid = Self.stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = Self.stringProperty(id, kAudioDevicePropertyDeviceNameCFString) else { continue }
            let transport = Self.transportType(id)
            let isExternal = transport != kAudioDeviceTransportTypeBuiltIn
            found.append(MicDevice(id: id, uid: uid, name: name, isExternal: isExternal))
        }
        let now = Date()
        for device in found where connectedAt[device.uid] == nil {
            connectedAt[device.uid] = now
        }
        // Built-in first, then externals by name — stable, predictable list.
        inputDevices = found.sorted {
            if $0.isExternal != $1.isExternal { return !$0.isExternal }
            return $0.name < $1.name
        }
        print("🎙️ Input devices: \(inputDevices.map { "\($0.name)\($0.isExternal ? " (ext)" : "")" })")
    }

    private func installDeviceListListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main
        ) { [weak self] _, _ in
            self?.refreshDevices()
        }
    }

    // MARK: - CoreAudio helpers (static, nonisolated-safe)

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let listPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { listPtr.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, listPtr) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(listPtr.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return kAudioDeviceTransportTypeUnknown
        }
        return value
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    static func systemDefaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
            id != kAudioObjectUnknown else { return nil }
        return id
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug -derivedDataPath ./build/DerivedData build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: SKIPPED — scratch verification waived by the user; behavior is verified manually in the dev build (Task 7 checklist). The build is this task's only gate.**

- [ ] **Step 4: Commit**

```bash
git add Airboard/MicDeviceManager.swift
git commit -m "Add MicDeviceManager: input enumeration and per-device mic rules"
```

---

### Task 2: MicCaptureEngine

**Files:**
- Create: `Airboard/MicCaptureEngine.swift`

**Interfaces:**
- Produces (used by Tasks 3–4):
  - `final class MicCaptureEngine` (one instance per recorder)
  - `func prepare()`
  - `func start(deviceID: AudioDeviceID?, fileURL: URL) throws`
  - `func rotate(to newURL: URL) -> URL?` (returns the finished file's URL)
  - `func stop() -> URL?` (returns the final file's URL)
  - `var currentPowerDb: Float` (approx dB; −160 = silence; safe to poll from timers)

- [ ] **Step 1: Write the file**

Create `Airboard/MicCaptureEngine.swift` with exactly:

```swift
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
```

- [ ] **Step 2: Build (adapt isolation syntax if needed)**

Run: `xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug -derivedDataPath ./build/DerivedData build 2>&1 | tail -8`
Expected: `** BUILD SUCCEEDED **`. If the compiler rejects `nonisolated` on the class declaration in this project's Swift mode, the accepted adaptation is: remove `nonisolated` from the class and instead ensure every member the tap closure touches (`handle`, `currentPowerDb`, the lock and its state) is marked `nonisolated`. The invariant that must hold: **the tap closure compiles and runs without any main-actor hop**.

- [ ] **Step 3: SKIPPED — scratch verification waived by the user; capture/rotation/format are verified manually in the dev build (Task 7 checklist). The build is this task's only gate.**

- [ ] **Step 4: Commit**

```bash
git add Airboard/MicCaptureEngine.swift
git commit -m "Add MicCaptureEngine: device-pinned capture to 16kHz mono WAV"
```

---

### Task 3: AudioRecorder onto the engine

**Files:**
- Modify: `Airboard/AudioRecorder.swift` (capture internals only)

**Interfaces:**
- Consumes: `MicCaptureEngine` (Task 2), `MicDeviceManager.shared.resolveActiveDeviceID()` (Task 1).
- Produces: unchanged public surface — `@Published isRecording`, `@Published recordingURL`, `startRecording()`, `stopRecording()`. The coordinator must not need edits.

- [ ] **Step 1: Replace the capture internals**

Read `Airboard/AudioRecorder.swift` first. Then replace the AVAudioRecorder-based members and methods (`audioRecorder`, `preparedRecorder`, `preparedURL`, `recordingSettings`, `prepareNextRecorder()`, `setupAudioSession()`, and the bodies of `startRecording()`/`stopRecording()`) so the class reads (keep `shouldAddLeadingSpace`? — no, that lives in TextInserter; keep the existing normalization trio `normalizeRecordedAudio`/`findPeakLevel`/`findRMSLevel`/`normalizeAudio` and `deinit` untouched):

```swift
import Foundation
import AVFoundation
import Combine

class AudioRecorder: ObservableObject {
    private let captureEngine = MicCaptureEngine()
    private var recordingStartTime: Date?

    @Published var isRecording = false
    @Published var recordingURL: URL?

    init() {
        // Warm the engine so startRecording() is fast at hotkey time
        // (replaces the old pre-prepared AVAudioRecorder trick).
        captureEngine.prepare()
    }

    func startRecording() {
        guard !isRecording else { return }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording_\(Date().timeIntervalSince1970).wav")
        let deviceID = MicDeviceManager.shared.resolveActiveDeviceID()

        do {
            try captureEngine.start(deviceID: deviceID, fileURL: url)
            isRecording = true
            recordingURL = url
            recordingStartTime = Date()
            print("🎙️ Recording started (\(MicDeviceManager.shared.activeMicName)): \(url.lastPathComponent)")
        } catch {
            print("❌ Recording failed to start: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        let finishedURL = captureEngine.stop()
        isRecording = false

        if let startTime = recordingStartTime {
            let duration = Date().timeIntervalSince(startTime)
            print("⏱️ Recording duration: \(String(format: "%.2f", duration))s")
        }
        recordingStartTime = nil

        guard let url = finishedURL else {
            print("⚠️ No recording URL available")
            return
        }
        recordingURL = url

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let fileSize = attributes[.size] as? Int64 {
                let sizeKB = Double(fileSize) / 1024.0
                print("📊 Recording size: \(String(format: "%.1f", sizeKB))KB")
                if fileSize >= 1000 {
                    normalizeRecordedAudio(url: url)
                } else {
                    print("⚠️ Recording too small - likely invalid")
                }
            }
        } catch {
            print("⚠️ Could not verify recording file: \(error.localizedDescription)")
        }
        print("🎙️ Recording stopped: \(url.path)")
    }

    // ... keep the existing normalizeRecordedAudio / findPeakLevel /
    //     findRMSLevel / normalizeAudio methods and deinit exactly as-is ...
}
```

Notes: the old `Thread.sleep(0.1)` after stop is no longer needed — `MicCaptureEngine.stop()` finalizes the file synchronously before returning. `recordingURL` is now set on stop (after the file is final); confirm the coordinator reads it only after `stopRecording()` returns (it does — `audioRecorder.recordingURL` is read in the stop path).

- [ ] **Step 2: Build**

Run: `xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug -derivedDataPath ./build/DerivedData build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Verify the coordinator contract didn't change**

Run: `grep -n "audioRecorder\." Airboard/TranscriptionCoordinator.swift`
Expected: only uses of `startRecording()`, `stopRecording()`, `recordingURL`, `isRecording` — all still provided. If anything else appears, STOP and report BLOCKED with the line.

- [ ] **Step 4: Commit**

```bash
git add Airboard/AudioRecorder.swift
git commit -m "AudioRecorder captures via MicCaptureEngine (device-pinnable)"
```

---

### Task 4: ChunkedAudioRecorder onto the engine

**Files:**
- Modify: `Airboard/ChunkedAudioRecorder.swift` (capture internals only)

**Interfaces:**
- Consumes: `MicCaptureEngine` (Task 2), `MicDeviceManager.shared.resolveActiveDeviceID()` (Task 1).
- Produces: unchanged public surface — `@Published isRecording/currentChunkNumber/totalDuration`, `onChunkComplete: ((URL, Int) -> Void)?`, `onRecordingComplete: (() -> Void)?`, `startRecording()`, `stopRecording()`.

- [ ] **Step 1: Replace the capture internals**

Read the file first. Keep: the chunk policy constants (`minChunkDuration` 25.0, `maxChunkDuration` 40.0, `silenceThresholdDb` -38.0), `processingQueue`, `finalizeChunkFile` (minus its `Thread.sleep` — files are final when the engine hands them back; delete that line), the normalization trio, `deinit`, and both timers' scheduling structure. Replace `audioRecorder`/`audioFormat`/`setupAudioSession` and rework these methods:

```swift
    private let captureEngine = MicCaptureEngine()

    func startRecording() {
        guard !isRecording else { return }

        isRecording = true
        recordingStartTime = Date()
        currentChunkNumber = 0
        totalDuration = 0

        let firstURL = nextChunkURL()
        let deviceID = MicDeviceManager.shared.resolveActiveDeviceID()
        do {
            try captureEngine.start(deviceID: deviceID, fileURL: firstURL)
            currentChunkURL = firstURL
            chunkStartTime = Date()
            print("🎬 Starting chunked recording (\(MicDeviceManager.shared.activeMicName))")
            scheduleChunkRotation()
        } catch {
            print("❌ Failed to start chunked recording: \(error.localizedDescription)")
            isRecording = false
        }
    }

    private func nextChunkURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("chunk_\(Date().timeIntervalSince1970)_\(currentChunkNumber).wav")
    }
```

`beginSilenceWatch()` keeps its structure; the meter read becomes the engine's level:

```swift
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, self.isRecording else { return }

            let power = self.captureEngine.currentPowerDb
            let elapsed = Date().timeIntervalSince(self.chunkStartTime ?? Date())

            if power < self.silenceThresholdDb || elapsed >= self.maxChunkDuration {
                self.meterTimer?.invalidate()
                self.meterTimer = nil
                let reason = power < self.silenceThresholdDb ? "pause detected" : "max duration"
                print("🔄 Rotating chunk (\(reason), \(String(format: "%.1f", elapsed))s)")
                self.rotateChunk()
            }
        }
```

`rotateChunk()` uses the engine's gap-free swap:

```swift
    private func rotateChunk() {
        guard isRecording else { return }

        let finishedNumber = currentChunkNumber
        currentChunkNumber += 1
        if let startTime = recordingStartTime {
            totalDuration = Date().timeIntervalSince(startTime)
        }

        let newURL = nextChunkURL()
        let finishedURL = captureEngine.rotate(to: newURL)
        currentChunkURL = newURL
        chunkStartTime = Date()
        scheduleChunkRotation()

        if let url = finishedURL {
            processingQueue.async { [weak self] in
                self?.finalizeChunkFile(url: url, chunkNumber: finishedNumber)
            }
        }
    }
```

`stopRecording()` keeps its structure; the recorder stop becomes:

```swift
        let lastNumber = currentChunkNumber
        let lastURL = captureEngine.stop()
        currentChunkURL = nil
```

(and the rest — timers invalidated first, `isRecording = false`, duration print, `processingQueue.async` finalize + `onRecordingComplete` hop — stays exactly as it is today).

- [ ] **Step 2: Build**

Run: `xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug -derivedDataPath ./build/DerivedData build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Verify the coordinator contract didn't change**

Run: `grep -n "chunkedRecorder\." Airboard/TranscriptionCoordinator.swift`
Expected: only `onChunkComplete`, `onRecordingComplete`, `startRecording()`, `stopRecording()` — all still provided.

- [ ] **Step 4: Commit**

```bash
git add Airboard/ChunkedAudioRecorder.swift
git commit -m "ChunkedAudioRecorder captures via MicCaptureEngine, gap-free rotation"
```

---

### Task 5: Popover "Microphone" row

**Files:**
- Modify: `Airboard/AirboardPopover.swift` (new row after the AI cleanup row)
- Modify: `Airboard/FloatingWindowManager.swift` (popover height → content-sized)

**Interfaces:**
- Consumes: `MicDeviceManager.shared` — `inputDevices`, `resolvedSelectionUID`, `activeMicName`, `selectMic(uid:)`, `refreshDevices()`.
- Produces: UI only.

- [ ] **Step 1: Add the row**

Read `Airboard/AirboardPopover.swift`. Add an observed object near the other properties:

```swift
    @ObservedObject private var micManager = MicDeviceManager.shared
```

Insert this row directly AFTER the AI cleanup row block (match neighboring row styling exactly — icon circle, 13/11pt, paddings):

```swift
                // Microphone picker
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.teal.opacity(0.1))
                            .frame(width: 32, height: 32)

                        Image(systemName: "mic.fill")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.teal)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Microphone")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.primary)

                        Text(micManager.activeMicName)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Menu {
                        ForEach(micManager.inputDevices) { device in
                            Button(action: { micManager.selectMic(uid: device.uid) }) {
                                if micManager.resolvedSelectionUID == device.uid {
                                    Label(device.name, systemImage: "checkmark")
                                } else {
                                    Text(device.name)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .onAppear { micManager.refreshDevices() }
```

- [ ] **Step 2: Content-size the popover window**

In `Airboard/FloatingWindowManager.swift`, the popover currently uses a fixed height constant (`let popoverHeight: CGFloat = ...` near the `AirboardPopover(...)` construction). Replace the fixed constant with content sizing, mirroring the cleanup-settings-window pattern already in this file:

```swift
        let popoverWidth: CGFloat = 280

        let hostingView = NSHostingView(rootView: popoverView)
        hostingView.frame.size.width = popoverWidth
        let popoverHeight = hostingView.fittingSize.height
        hostingView.frame = NSRect(x: 0, y: 0, width: popoverWidth, height: popoverHeight)
```

(`popoverHeight` remains a local used by the window contentRect and positioning math below it — those lines stay unchanged.)

- [ ] **Step 3: Build**

Run: `xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug -derivedDataPath ./build/DerivedData build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Airboard/AirboardPopover.swift Airboard/FloatingWindowManager.swift
git commit -m "Add Microphone picker row with per-device memory to popover"
```

---

### Task 6: Docs and changelog

**Files:**
- Modify: `CLAUDE.md`, `README.md`, `CHANGELOG.md`

- [ ] **Step 1: CLAUDE.md**

1. Source Organization table, Audio capture row → `| Audio capture | \`AudioRecorder.swift\`, \`ChunkedAudioRecorder.swift\` (policy) on \`MicCaptureEngine.swift\` (device-pinned capture); \`MicDeviceManager.swift\` (device list + per-device rules) |`
2. UserDefaults Keys: add `- \`micRuleByDevice\` — per-external-device mic choice (externalDeviceUID → chosenMicUID); no rule = system default`

- [ ] **Step 2: README.md**

Features: add bullet `- **🎤 Pick your mic**: choose which microphone Airboard records from — remembered per headset, so connecting Bluetooth earphones never silently downgrades your transcription quality`.

- [ ] **Step 3: CHANGELOG.md**

Under `## [Unreleased]` add:

```markdown
### Added
- Microphone selection with per-device memory: pick which mic Airboard uses from the menu popover; the choice is remembered for each connected headset (e.g. keep using the MacBook mic when Bluetooth earphones connect)
```

(If an `### Added` section already exists under `[Unreleased]`, append the bullet to it.)

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md README.md CHANGELOG.md
git commit -m "Docs for microphone selection"
```

---

### Task 7: Final verification and handoff

**Files:** none (verification only)

- [ ] **Step 1: Clean build both configs**

Run: `xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug -derivedDataPath ./build/DerivedData clean build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

Run: `xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Release -derivedDataPath ./build/DerivedData-rel -destination "generic/platform=macOS" -archivePath ./build/DerivedData-rel/verify.xcarchive archive 2>&1 | tail -3`
Expected: `** ARCHIVE SUCCEEDED **` (proves the release path still signs/builds with the new files).

- [ ] **Step 2: Launch the dev build**

```bash
pkill -f "Airboard Dev.app" 2>/dev/null; sleep 1
open "./build/DerivedData/Build/Products/Debug/Airboard Dev.app"
sleep 8 && ps aux | grep "Airboard Dev.app/Contents/MacOS" | grep -v grep
```

Expected: process running. Check the console/log for the `🎙️ Input devices:` line listing at least the built-in mic.

- [ ] **Step 3: Report with the user's eyes-on checklist (verbatim, from the spec)**

1. Mac alone: dictation works; the Microphone dropdown lists only the MacBook mic; subtitle shows it.
2. Connect Bluetooth earphones (no rule yet): dictation follows the system default (earphones mic — quality drop expected and proves scenario 2); dropdown now lists both.
3. Pick "MacBook Microphone" while earphones are connected: next dictation is high quality; audio output still plays through the earphones.
4. Disconnect + reconnect the earphones, then quit + relaunch Airboard: MacBook mic is still used automatically (rule persisted).
5. Hold the hotkey and speak IMMEDIATELY: first words are not clipped (capture-layer latency regression check).
6. Hands-free (double-tap): chunks rotate at pauses, text inserts live, correct mic used.
7. Command mode still works.
8. Popover: AI cleanup subtitle reads "Grammar" untruncated; popover height fits all rows without clipping.
