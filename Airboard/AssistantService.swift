//
//  AssistantService.swift
//
//  Spawns the pi coding agent headlessly to answer one voice question.
//  Probe-verified contract (2026-07-28): stdin MUST be closed or pi hangs
//  forever; hermetic flags keep the user's personal pi setup out; the
//  extension provides the ONLY tools (calc, fetch_url).
//

import Foundation

enum AssistantOutcome {
    case answer(String)
    case unsupported(String)
    case needsPi
    case needsKey
    case timeout
    case failure
}

final class AssistantService {
    static let shared = AssistantService()
    static let openRouterHost = "openrouter.ai"
    static let modelDefaultsKey = "assistantModel"
    static let defaultModel = "openai/gpt-oss-120b:low"
    private static let timeoutSeconds: TimeInterval = 60

    private var cachedPiPath: String?
    private var piPathChecked = false

    private init() {}

    // MARK: - Status (settings UI + preflight)

    /// Resolve pi via a login shell — GUI apps don't inherit shell PATH.
    /// Caches both success AND failure so repeated calls while pi is missing
    /// don't re-spawn a blocking login shell on every isPiInstalled()/ask().
    private func piPath() -> String? {
        if piPathChecked { return cachedPiPath }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "which pi"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        guard (try? proc.run()) != nil else {
            piPathChecked = true
            return nil
        }
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard proc.terminationStatus == 0, !out.isEmpty, FileManager.default.isExecutableFile(atPath: out) else {
            piPathChecked = true
            return nil
        }
        cachedPiPath = out
        piPathChecked = true
        return out
    }

    func invalidatePiPathCache() {
        cachedPiPath = nil
        piPathChecked = false
    }
    func isPiInstalled() -> Bool { piPath() != nil }
    func hasKey() -> Bool { KeychainHelper.hasAPIKey(forHost: Self.openRouterHost) }

    private var model: String {
        let m = UserDefaults.standard.string(forKey: Self.modelDefaultsKey) ?? ""
        return m.isEmpty ? Self.defaultModel : m
    }

    /// Neutral working directory — never the user's cwd.
    private func workDir() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.pype.airboard")
            .appendingPathComponent("assistant")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Ask

    func ask(_ question: String) async -> (outcome: AssistantOutcome, durationMs: Int) {
        let started = Date()
        func done(_ o: AssistantOutcome) -> (AssistantOutcome, Int) {
            (o, Int(Date().timeIntervalSince(started) * 1000))
        }

        guard let pi = piPath() else { return done(.needsPi) }
        guard let key = KeychainHelper.readAPIKey(forHost: Self.openRouterHost), !key.isEmpty else {
            return done(.needsKey)
        }
        // Bundled as .txt (Xcode won't copy .ts to Resources); pi needs the
        // real extension to transpile, so stage a .ts copy in our workdir.
        guard let extSrc = Bundle.main.url(forResource: "assistant-tools", withExtension: "txt") else {
            print("❌ Assistant: bundled extension missing")
            return done(.failure)
        }
        let extTS = workDir().appendingPathComponent("assistant-tools.ts")
        do {
            try? FileManager.default.removeItem(at: extTS)
            try FileManager.default.copyItem(at: extSrc, to: extTS)
        } catch {
            print("❌ Assistant: failed to stage extension: \(error)")
            return done(.failure)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pi)
        proc.currentDirectoryURL = workDir()
        proc.arguments = [
            "-p", "--no-session", "--no-extensions", "--no-skills",
            "--no-context-files", "--no-builtin-tools", "--offline",
            "-e", extTS.path,
            "--provider", "openrouter",
            "--model", model,
            // Step 1 probe (2026-07-29) confirmed OPENROUTER_API_KEY env var
            // works with auth.json absent — no --api-key fallback needed.
            "--system-prompt", AssistantPrompt.systemPrompt(),
            question,
        ]
        var env = ProcessInfo.processInfo.environment
        env["OPENROUTER_API_KEY"] = key
        proc.environment = env

        let stdout = Pipe()
        proc.standardOutput = stdout
        proc.standardError = FileHandle.nullDevice  // keep pi's stderr out of our log noise (and unread pipe from filling/blocking)
        proc.standardInput = FileHandle.nullDevice  // CRITICAL: open stdin = infinite hang

        do { try proc.run() } catch {
            print("❌ Assistant: failed to spawn pi: \(error)")
            return done(.failure)
        }

        // CRITICAL: drain stdout concurrently with waiting for termination — if
        // pi writes more than the kernel pipe buffer, the child blocks writing
        // and never exits unless someone is reading stdout in the meantime.
        let readTask = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }

        let timedOut = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let lock = NSLock()
            var finished = false
            proc.terminationHandler = { _ in
                lock.lock(); defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                cont.resume(returning: false)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeoutSeconds) {
                lock.lock(); defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                proc.terminate()
                // Escalate if terminate() (SIGTERM) doesn't take within 3s.
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
                }
                cont.resume(returning: true)
            }
        }
        if timedOut { return done(.timeout) }

        let raw = String(data: await readTask.value, encoding: .utf8) ?? ""
        guard proc.terminationStatus == 0 else {
            print("❌ Assistant: pi exited \(proc.terminationStatus): \(raw.prefix(300))")
            return done(.failure)
        }
        switch AssistantPrompt.parse(raw) {
        case .answer(let text): return done(.answer(text))
        case .unsupported(let reason): return done(.unsupported(reason))
        case .empty: return done(.failure)
        }
    }
}
