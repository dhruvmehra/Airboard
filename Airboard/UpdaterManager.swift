//
//  UpdaterManager.swift
//
//  Owns the Sparkle updater. Fully-automatic behavior (check at launch +
//  daily, background download, install on quit) is configured in Info.plist
//  (SUEnableAutomaticChecks / SUAutomaticallyUpdate). This class decides
//  only WHETHER the updater runs: production bundle only — dev builds
//  never contact the feed.
//  See docs/superpowers/specs/2026-07-19-sparkle-auto-update-design.md
//

import Foundation
import Sparkle

class UpdaterManager {
    static let shared = UpdaterManager()

    /// Auto-update is armed only for the production app; the dev build
    /// (com.pype.airboard.dev) must never phone home or self-replace.
    static let isEnabled = Bundle.main.bundleIdentifier == "com.pype.airboard"

    private var controller: SPUStandardUpdaterController?

    private init() {}

    /// Called once at launch. No-op in dev builds.
    func start() {
        guard Self.isEnabled, controller == nil else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        print("🔄 Sparkle updater started (feed: \(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") ?? "?"))")
    }

    /// User-initiated check from the popover — shows Sparkle's UI.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
