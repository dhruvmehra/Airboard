# Parakeet ASR Swap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace WhisperKit (Whisper large-v3-turbo) with Parakeet TDT 0.6B v3 via FluidAudio as Airboard's local speech-to-text engine.

**Architecture:** `ParakeetTranscriptionService` (new) replaces `LocalTranscriptionService` behind the same published-property surface consumed by `TranscriptionCoordinator`. A trivial `TranscriptPostProcessor` seam is added for a future LLM stage. The custom vocabulary feature and WhisperKit are removed; an orphaned Whisper model cache is cleaned up on launch.

**Tech Stack:** Swift 5 (project uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), SwiftUI/AppKit, Combine, FluidAudio 0.15.5 (SPM), CoreML.

**Spec:** `docs/superpowers/specs/2026-07-18-parakeet-swap-design.md`

## Global Constraints

- Repo root is `/Users/dhruvmehra/Desktop/proj/Airboard/Airboard` (contains `Airboard.xcodeproj`); all paths below are relative to it. All commands run from it.
- Deployment target macOS 14.0; do not change it.
- FluidAudio pinned to **exact version 0.15.5**; model version **`.v3`** (`AsrModelVersion.v3`).
- The Xcode project uses a `PBXFileSystemSynchronizedRootGroup` — any `.swift` file created in or deleted from `Airboard/` is automatically added to/removed from the target. No pbxproj edit needed for source files.
- No XCTest target exists and none is added. Each task's verification is a successful build:
  `xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug -derivedDataPath ./build/DerivedData build 2>&1 | tail -5` → expect `** BUILD SUCCEEDED **`. Final user-facing behavior is manually tested by the user (spec §Verification).
- The project's default actor isolation is MainActor: class properties can be set directly in async methods without `MainActor.run`, EXCEPT inside `@Sendable` closures, which need `Task { @MainActor in ... }`.
- Known limitation (documented in Task 7): FluidAudio's Parakeet models require Apple Silicon at runtime. The universal (x86_64+arm64) release build still compiles; Intel Macs get a clear error instead of transcription.
- Commit after every task with the exact message given in the task.

---

### Task 1: Add FluidAudio SPM dependency

**Files:**
- Modify: `Airboard.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `import FluidAudio` available to all target sources.

- [ ] **Step 1: Add the package reference to the PBXProject `packageReferences` list**

In `Airboard.xcodeproj/project.pbxproj` find:

```
			packageReferences = (
				CC26B8282EDE2D8A00B10FA0 /* XCRemoteSwiftPackageReference "WhisperKit" */,
			);
```

Replace with:

```
			packageReferences = (
				CC26B8282EDE2D8A00B10FA0 /* XCRemoteSwiftPackageReference "WhisperKit" */,
				FA1DA0D10000000000000001 /* XCRemoteSwiftPackageReference "FluidAudio" */,
			);
```

- [ ] **Step 2: Add the remote package definition**

Find:

```
/* Begin XCRemoteSwiftPackageReference section */
		CC26B8282EDE2D8A00B10FA0 /* XCRemoteSwiftPackageReference "WhisperKit" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/argmaxinc/WhisperKit";
			requirement = {
				kind = revision;
				revision = ba094495e40ff255f30ca4602e2c75994f255df7;
			};
		};
/* End XCRemoteSwiftPackageReference section */
```

Replace with:

```
/* Begin XCRemoteSwiftPackageReference section */
		CC26B8282EDE2D8A00B10FA0 /* XCRemoteSwiftPackageReference "WhisperKit" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/argmaxinc/WhisperKit";
			requirement = {
				kind = revision;
				revision = ba094495e40ff255f30ca4602e2c75994f255df7;
			};
		};
		FA1DA0D10000000000000001 /* XCRemoteSwiftPackageReference "FluidAudio" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/FluidInference/FluidAudio.git";
			requirement = {
				kind = exactVersion;
				version = 0.15.5;
			};
		};
/* End XCRemoteSwiftPackageReference section */
```

- [ ] **Step 3: Add the product dependency**

Find:

```
/* Begin XCSwiftPackageProductDependency section */
		CC9F704A2EDF830500F2670F /* WhisperKit */ = {
			isa = XCSwiftPackageProductDependency;
			package = CC26B8282EDE2D8A00B10FA0 /* XCRemoteSwiftPackageReference "WhisperKit" */;
			productName = WhisperKit;
		};
/* End XCSwiftPackageProductDependency section */
```

Replace with:

```
/* Begin XCSwiftPackageProductDependency section */
		CC9F704A2EDF830500F2670F /* WhisperKit */ = {
			isa = XCSwiftPackageProductDependency;
			package = CC26B8282EDE2D8A00B10FA0 /* XCRemoteSwiftPackageReference "WhisperKit" */;
			productName = WhisperKit;
		};
		FA1DA0D10000000000000002 /* FluidAudio */ = {
			isa = XCSwiftPackageProductDependency;
			package = FA1DA0D10000000000000001 /* XCRemoteSwiftPackageReference "FluidAudio" */;
			productName = FluidAudio;
		};
/* End XCSwiftPackageProductDependency section */
```

- [ ] **Step 4: Add the build file and link it in the Frameworks phase**

Find:

```
/* Begin PBXBuildFile section */
		CC9F704B2EDF830500F2670F /* WhisperKit in Frameworks */ = {isa = PBXBuildFile; productRef = CC9F704A2EDF830500F2670F /* WhisperKit */; };
/* End PBXBuildFile section */
```

Replace with:

```
/* Begin PBXBuildFile section */
		CC9F704B2EDF830500F2670F /* WhisperKit in Frameworks */ = {isa = PBXBuildFile; productRef = CC9F704A2EDF830500F2670F /* WhisperKit */; };
		FA1DA0D10000000000000003 /* FluidAudio in Frameworks */ = {isa = PBXBuildFile; productRef = FA1DA0D10000000000000002 /* FluidAudio */; };
/* End PBXBuildFile section */
```

Then find:

```
			files = (
				CC9F704B2EDF830500F2670F /* WhisperKit in Frameworks */,
			);
```

Replace with:

```
			files = (
				CC9F704B2EDF830500F2670F /* WhisperKit in Frameworks */,
				FA1DA0D10000000000000003 /* FluidAudio in Frameworks */,
			);
```

Finally, add FluidAudio to the target's package products. Find:

```
			packageProductDependencies = (
				CC9F704A2EDF830500F2670F /* WhisperKit */,
			);
```

Replace with:

```
			packageProductDependencies = (
				CC9F704A2EDF830500F2670F /* WhisperKit */,
				FA1DA0D10000000000000002 /* FluidAudio */,
			);
```

- [ ] **Step 5: Resolve and build**

Run: `xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug -derivedDataPath ./build/DerivedData build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **` (first run downloads the FluidAudio package; `Package.resolved` gains a fluidaudio entry).

- [ ] **Step 6: Commit**

```bash
git add Airboard.xcodeproj
git commit -m "Add FluidAudio 0.15.5 dependency"
```

---

### Task 2: Create ParakeetTranscriptionService

**Files:**
- Create: `Airboard/ParakeetTranscriptionService.swift`

**Interfaces:**
- Consumes: FluidAudio (`AsrModels`, `AsrManager`, `AsrModelVersion`, `TdtDecoderState`, `DownloadProgress`).
- Produces (used by Task 4's coordinator rewire — must match exactly):
  - `class ParakeetTranscriptionService: ObservableObject`
  - `@Published var transcription: String`
  - `@Published var isTranscribing: Bool`
  - `@Published var error: String?`
  - `@Published var isDownloadingModel: Bool`
  - `@Published var downloadProgress: Double`
  - `@Published var isModelReady: Bool`
  - `func ensureModelReady() async`
  - `func transcribe(audioURL: URL) async` — note: **no `context:` parameter**

- [ ] **Step 1: Write the service**

Create `Airboard/ParakeetTranscriptionService.swift` with exactly:

```swift
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
    func ensureModelReady() async {
        await initializationTask?.value
        if !isModelReady {
            initializationTask = Task {
                await initializeParakeet()
            }
            await initializationTask?.value
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
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug -derivedDataPath ./build/DerivedData build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`. If FluidAudio 0.15.5 has drifted from the API used above (`AsrModels.defaultCacheDirectory(for:)`, `AsrModels.modelsExist(at:version:)`, `AsrModels.downloadAndLoad(version:progressHandler:)`, `AsrManager(config:)`, `loadModels(_:)`, `decoderLayerCount`, `TdtDecoderState.make(decoderLayers:)`, `transcribe(_:decoderState:)`), consult the checked-out package source under `./build/DerivedData/SourcePackages/checkouts/FluidAudio/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/` and adapt — the published-property surface in **Interfaces** must not change.

- [ ] **Step 3: Commit**

```bash
git add Airboard/ParakeetTranscriptionService.swift
git commit -m "Add ParakeetTranscriptionService (FluidAudio, Parakeet TDT v3)"
```

---

### Task 3: Create TranscriptPostProcessor seam

**Files:**
- Create: `Airboard/TranscriptPostProcessor.swift`

**Interfaces:**
- Consumes: `AppContext` (existing type in `AppContextDetector.swift`).
- Produces (used by Task 4): `TranscriptPostProcessor.process(_ text: String, context: AppContext?) -> String`

- [ ] **Step 1: Write the seam**

Create `Airboard/TranscriptPostProcessor.swift` with exactly:

```swift
//
//  TranscriptPostProcessor.swift
//
//  Seam for a future LLM cleanup stage (filler removal, grammar, tone per
//  app context). Currently a pass-through — see
//  docs/superpowers/specs/2026-07-18-parakeet-swap-design.md
//

import Foundation

enum TranscriptPostProcessor {
    /// Applied to every transcript before command detection / insertion.
    static func process(_ text: String, context: AppContext?) -> String {
        return text
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug -derivedDataPath ./build/DerivedData build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Airboard/TranscriptPostProcessor.swift
git commit -m "Add TranscriptPostProcessor seam for future LLM stage"
```

---

### Task 4: Rewire TranscriptionCoordinator to Parakeet

**Files:**
- Modify: `Airboard/TranscriptionCoordinator.swift` (service property ~line 19; chunk path ~lines 300–331; dictation path ~lines 381–412)

**Interfaces:**
- Consumes: `ParakeetTranscriptionService` (Task 2), `TranscriptPostProcessor.process(_:context:)` (Task 3).
- Produces: no interface changes — coordinator's own API is unchanged.

- [ ] **Step 1: Swap the service**

In `Airboard/TranscriptionCoordinator.swift` find:

```swift
    private let transcriptionService = LocalTranscriptionService()
```

Replace with:

```swift
    private let transcriptionService = ParakeetTranscriptionService()
```

(The observers on `$downloadProgress`/`$isModelReady` and all `isModelReady`/`ensureModelReady()` call sites keep working — the new service exposes identical property names.)

- [ ] **Step 2: Update the chunk call site (hands-free path)**

In `handleChunkCompletion(url:chunkNumber:)` find:

```swift
            await transcriptionService.transcribe(audioURL: url, context: currentContext)
```

Replace with:

```swift
            await transcriptionService.transcribe(audioURL: url)
```

Then, in the same method, find:

```swift
            print("✅ Chunk \(chunkNumber) FINAL TEXT: '\(text)'")

            // Accumulate text
            await MainActor.run {
                if !accumulatedText.isEmpty {
                    accumulatedText += " "
                }
                accumulatedText += text

                // Insert text immediately for real-time feedback
                if isHandsFreeMode {
                    insertTextIntoTargetApp(text)
                }
            }
```

Replace with:

```swift
            let cleanedText = TranscriptPostProcessor.process(text, context: currentContext)
            print("✅ Chunk \(chunkNumber) FINAL TEXT: '\(cleanedText)'")

            // Accumulate text
            await MainActor.run {
                if !accumulatedText.isEmpty {
                    accumulatedText += " "
                }
                accumulatedText += cleanedText

                // Insert text immediately for real-time feedback
                if isHandsFreeMode {
                    insertTextIntoTargetApp(cleanedText)
                }
            }
```

- [ ] **Step 3: Update the dictation call site**

In `processTranscription(audioURL:)` find:

```swift
        await transcriptionService.transcribe(audioURL: audioURL, context: currentContext)
```

Replace with:

```swift
        await transcriptionService.transcribe(audioURL: audioURL)
```

Then, in the same method, find:

```swift
        lastTranscribedText = text
        lastContext = currentContext

        // End transcription timing
        PerformanceMonitor.shared.endTranscription(inputText: text)

        print("📝 Transcription: \"\(text)\"")
        print("📍 Mode: \(currentMode == .command ? "COMMAND" : "DICTATION")")

        // Handle based on mode
        if currentMode == .command {
            await handleCommandMode(text: text)
        } else {
            await handleDictationMode(text: text)
        }
```

Replace with:

```swift
        let cleanedText = TranscriptPostProcessor.process(text, context: currentContext)
        lastTranscribedText = cleanedText
        lastContext = currentContext

        // End transcription timing
        PerformanceMonitor.shared.endTranscription(inputText: cleanedText)

        print("📝 Transcription: \"\(cleanedText)\"")
        print("📍 Mode: \(currentMode == .command ? "COMMAND" : "DICTATION")")

        // Handle based on mode
        if currentMode == .command {
            await handleCommandMode(text: cleanedText)
        } else {
            await handleDictationMode(text: cleanedText)
        }
```

- [ ] **Step 4: Build**

Run: `xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug -derivedDataPath ./build/DerivedData build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Airboard/TranscriptionCoordinator.swift
git commit -m "Wire coordinator to Parakeet service and post-processor seam"
```

---

### Task 5: Remove WhisperKit and LocalTranscriptionService

**Files:**
- Delete: `Airboard/LocalTranscriptionService.swift`
- Modify: `Airboard.xcodeproj/project.pbxproj` (remove the six WhisperKit entries — the same six spots where Task 1 added FluidAudio)

- [ ] **Step 1: Delete the old service**

```bash
git rm Airboard/LocalTranscriptionService.swift
```

- [ ] **Step 2: Remove WhisperKit from the pbxproj**

In `Airboard.xcodeproj/project.pbxproj` delete these lines (keep the FluidAudio lines added in Task 1):

1. In the `PBXBuildFile` section:
```
		CC9F704B2EDF830500F2670F /* WhisperKit in Frameworks */ = {isa = PBXBuildFile; productRef = CC9F704A2EDF830500F2670F /* WhisperKit */; };
```
2. In the Frameworks phase `files = (...)`:
```
				CC9F704B2EDF830500F2670F /* WhisperKit in Frameworks */,
```
3. In `packageProductDependencies = (...)`:
```
				CC9F704A2EDF830500F2670F /* WhisperKit */,
```
4. In `packageReferences = (...)`:
```
				CC26B8282EDE2D8A00B10FA0 /* XCRemoteSwiftPackageReference "WhisperKit" */,
```
5. The whole WhisperKit block in the `XCRemoteSwiftPackageReference` section:
```
		CC26B8282EDE2D8A00B10FA0 /* XCRemoteSwiftPackageReference "WhisperKit" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/argmaxinc/WhisperKit";
			requirement = {
				kind = revision;
				revision = ba094495e40ff255f30ca4602e2c75994f255df7;
			};
		};
```
6. The whole WhisperKit block in the `XCSwiftPackageProductDependency` section:
```
		CC9F704A2EDF830500F2670F /* WhisperKit */ = {
			isa = XCSwiftPackageProductDependency;
			package = CC26B8282EDE2D8A00B10FA0 /* XCRemoteSwiftPackageReference "WhisperKit" */;
			productName = WhisperKit;
		};
```

- [ ] **Step 3: Verify no stray references, then build**

Run: `grep -rn "WhisperKit\|whisperKit" Airboard/ Airboard.xcodeproj/project.pbxproj`
Expected: no output.

Run: `xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug -derivedDataPath ./build/DerivedData build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **` (`Package.resolved` drops whisperkit and its transitive deps).

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "Remove WhisperKit and LocalTranscriptionService"
```

---

### Task 6: Remove the custom vocabulary feature

**Files:**
- Delete: `Airboard/VocabularyManager.swift`, `Airboard/DictionaryView.swift`
- Modify: `Airboard/AirboardPopover.swift` (param ~line 16, state ~line 23, button block ~lines 126–163, preview ~line 530), `Airboard/FloatingWindowManager.swift` (callback ~line 272, `dictionaryWindow` property, `handleOpenDictionary`, `showDictionaryWindow` ~lines 405–430)

- [ ] **Step 1: Delete the two files**

```bash
git rm Airboard/VocabularyManager.swift Airboard/DictionaryView.swift
```

- [ ] **Step 2: Remove the Dictionary UI from AirboardPopover**

In `Airboard/AirboardPopover.swift`:
1. Delete the parameter declaration `let onOpenDictionary: () -> Void` (~line 16).
2. Delete the state `@State private var isHoveringDictionary = false` (~line 23).
3. Delete the whole "Dictionary Button" block — from the comment `// Dictionary Button` through the `.onHover { isHoveringDictionary = $0 }` line that closes that `Button` (~lines 126–163). Read the file first and delete exactly that one `Button(action: onOpenDictionary) { ... }` element including its trailing modifiers.
4. In the SwiftUI preview at the bottom (~line 530), delete the argument line `onOpenDictionary: {},`.

- [ ] **Step 3: Remove the Dictionary wiring from FloatingWindowManager**

In `Airboard/FloatingWindowManager.swift`:
1. In the `AirboardPopover(...)` construction (~line 262), delete the argument:
```swift
            onOpenDictionary: { [weak self] in
                self?.handleOpenDictionary()
            },
```
2. Delete the `handleOpenDictionary` method, the `showDictionaryWindow` method (the whole `// MARK: - Dictionary Window` block, ~lines 405–430), and the `dictionaryWindow` stored property. Find them with: `grep -n "dictionary\|Dictionary" Airboard/FloatingWindowManager.swift`

- [ ] **Step 4: Verify zero references, then build**

Run: `grep -rn "Vocabulary\|DictionaryView\|onOpenDictionary\|dictionaryWindow" Airboard/`
Expected: no output. (`grep -rn "Dictionary" Airboard/` may still match `infoDictionary` in `FeedbackManager.swift` — that is unrelated and stays.)

Run: `xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug -derivedDataPath ./build/DerivedData build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Remove custom vocabulary feature (no mechanism in Parakeet)"
```

---

### Task 7: One-time legacy Whisper cache cleanup

**Files:**
- Modify: `Airboard/AirboardApp.swift` (add method + call in `applicationDidFinishLaunching`)

- [ ] **Step 1: Add the cleanup**

In `Airboard/AirboardApp.swift`, inside `class AppDelegate`, add this method after `suppressLibraryLogs()`:

```swift
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
```

Then in `applicationDidFinishLaunching`, directly after the line `suppressLibraryLogs()`, add:

```swift
        cleanupLegacyWhisperModels()
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug -derivedDataPath ./build/DerivedData build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Airboard/AirboardApp.swift
git commit -m "Clean up orphaned Whisper model cache on launch"
```

---

### Task 8: Update documentation and changelog

**Files:**
- Modify: `CLAUDE.md`, `README.md`, `CHANGELOG.md`

- [ ] **Step 1: Update CLAUDE.md**

1. Project Overview: replace "All ML inference runs locally using WhisperKit (Whisper large-v3-turbo, speech-to-text)." with "All ML inference runs locally using FluidAudio (NVIDIA Parakeet TDT 0.6B v3, speech-to-text, CoreML/ANE — requires Apple Silicon)."
2. Dependencies table: replace the WhisperKit row with:
```
| FluidAudio (pinned to 0.15.5) | Local speech-to-text (Parakeet TDT 0.6B v3, CoreML) |
```
3. Replace the model auto-download note with:
```
Model auto-downloads on first run (version defined in `ParakeetTranscriptionService.modelVersion`); cache path is printed at launch (`AsrModels.defaultCacheDirectory`).
```
4. Architecture Core Flow: replace `LocalTranscriptionService (WhisperKit transcription)` with `ParakeetTranscriptionService (FluidAudio/Parakeet transcription)` and add a line after it: `→ TranscriptPostProcessor (pass-through seam for future LLM cleanup)`.
5. Source Organization table: ML inference row → `ParakeetTranscriptionService.swift`; Settings row → remove `VocabularyManager.swift`. Add a row: `| Post-processing | TranscriptPostProcessor.swift (identity; future LLM stage) |`.

- [ ] **Step 2: Update README.md**

1. Features: delete the "📖 Custom vocabulary" bullet. Update the "🔒 Fully local & private" bullet to reference [FluidAudio](https://github.com/FluidInference/FluidAudio) / NVIDIA Parakeet instead of WhisperKit.
2. Requirements: change "macOS 14.0 or later (Apple Silicon recommended)" to "macOS 14.0 or later with Apple Silicon (required for the speech model)".
3. First-run table: replace the Whisper row with:
```
| Parakeet TDT 0.6B v3 (FluidAudio) | Speech → text | ~1 GB | printed at launch |
```
and update the surrounding prose ("downloads its speech model (~1 GB)").
4. Usage: remove the sentence fragment about custom vocabulary in "Hotkey and custom vocabulary are configurable from the menu-bar popover." → "The hotkey is configurable from the menu-bar popover."
5. Architecture diagram: `LocalTranscriptionService (WhisperKit, local)` → `ParakeetTranscriptionService (FluidAudio/Parakeet, local)`.
6. Privacy: "The model is downloaded once from Hugging Face, then runs fully offline." stays true — no change.
7. Acknowledgments: replace the WhisperKit and OpenAI Whisper bullets with `[FluidAudio](https://github.com/FluidInference/FluidAudio) by Fluid Inference for on-device Parakeet` and `NVIDIA Parakeet`.

- [ ] **Step 3: Add CHANGELOG entries**

In `CHANGELOG.md` under `## [Unreleased]`, add to the `### Changed` list:

```markdown
- Swapped the speech engine from Whisper large-v3-turbo (WhisperKit) to NVIDIA Parakeet TDT 0.6B v3 (FluidAudio): better English accuracy and ~10× faster transcription. Requires Apple Silicon.
```

And to the `### Removed` list:

```markdown
- Custom vocabulary feature (its mechanism was Whisper-specific; superseded by a future LLM cleanup stage)
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md README.md CHANGELOG.md
git commit -m "Update docs for Parakeet swap"
```

---

### Task 9: Final verification

**Files:** none (verification only)

- [ ] **Step 1: Clean debug build**

Run: `xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Debug -derivedDataPath ./build/DerivedData clean build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Universal release build compiles**

(Guards the next `./build_release.sh` run — FluidAudio must compile for x86_64 even though it requires Apple Silicon at runtime.)

Run: `xcodebuild -project Airboard.xcodeproj -scheme Airboard -configuration Release -derivedDataPath ./build/DerivedData-rel -destination "generic/platform=macOS" ARCHS="x86_64 arm64" ONLY_ACTIVE_ARCH=NO build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`. If x86_64 fails to compile, report it — the fallback (drop x86_64 from `build_release.sh` and note it in README) is a user decision, not something to do silently.

- [ ] **Step 3: Launch and watch initialization**

```bash
open "./build/DerivedData/Build/Products/Debug/Airboard Dev.app"
```

Then confirm the process is alive and initialization progresses (first run downloads ~1GB — this may take minutes):

```bash
sleep 30 && ps aux | grep "Airboard Dev.app" | grep -v grep
```

Expected: process running; no crash. Model download/compile continues in background.

- [ ] **Step 4: Hand off to the user**

The user runs the manual acceptance tests from the spec: fresh-launch download → short dictation → long dictation (>15s) → hands-free → command mode → dictation before ready → old Whisper cache gone (`ls ~/Documents/huggingface/models/argmaxinc/ 2>/dev/null` → empty/missing).

- [ ] **Step 5: Push**

```bash
git push origin main
```
