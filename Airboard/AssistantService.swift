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
    private var cachedLoginPath: String?
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
        // Also capture the login shell's PATH: pi is a Node script
        // (#!/usr/bin/env node), and the GUI app's bare PATH has no
        // /opt/homebrew/bin — spawning pi without the real PATH dies with
        // "env: node: No such file or directory". (Field bug 2026-07-29.)
        proc.arguments = ["-lc", "echo \"AIRBOARD_LOGIN_PATH:$PATH\"; which pi"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        guard (try? proc.run()) != nil else {
            piPathChecked = true
            return nil
        }
        proc.waitUntilExit()
        // Login-shell startup can echo dotfile noise to stdout before "which"
        // runs; only the LAST non-empty line is trustworthy as the path.
        let rawOutput = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let lines = rawOutput.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let marker = lines.first(where: { $0.hasPrefix("AIRBOARD_LOGIN_PATH:") }) {
            cachedLoginPath = String(marker.dropFirst("AIRBOARD_LOGIN_PATH:".count))
        }
        let out = lines.filter { !$0.hasPrefix("AIRBOARD_LOGIN_PATH:") }.last ?? ""
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
        // Unique per-call filename — two concurrent asks (e.g. session B
        // starting while A's ask is still in flight) must not race on a
        // shared assistant-tools.ts (one's remove+copy could clobber the
        // other's staged file mid-read, producing a spurious .failure).
        let extTS = workDir().appendingPathComponent("assistant-tools-\(UUID().uuidString).ts")
        do {
            try FileManager.default.copyItem(at: extSrc, to: extTS)
        } catch {
            print("❌ Assistant: failed to stage extension: \(error)")
            return done(.failure)
        }
        defer { try? FileManager.default.removeItem(at: extTS) }

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
        // Hand the child the user's real login PATH so pi's `env node`
        // shebang resolves (GUI PATH lacks /opt/homebrew/bin).
        if let loginPath = cachedLoginPath, !loginPath.isEmpty {
            env["PATH"] = loginPath
        } else {
            env["PATH"] = (env["PATH"] ?? "/usr/bin:/bin") + ":/opt/homebrew/bin:/usr/local/bin"
        }
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
            func finish(_ didTimeOut: Bool) {
                lock.lock(); defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                cont.resume(returning: didTimeOut)
            }
            proc.terminationHandler = { _ in finish(false) }
            // Foundation never invokes a terminationHandler attached AFTER
            // the process already exited — a fast-failing pi (e.g. node not
            // on PATH, exit within ms of run()) would otherwise ghost into
            // a 60s phantom timeout. (Field bug 2026-07-29.)
            if !proc.isRunning { finish(false) }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeoutSeconds) {
                if proc.isRunning {
                    proc.terminate()
                    // Escalate if terminate() (SIGTERM) doesn't take within 3s.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                        if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
                    }
                }
                finish(true)
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
