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

    nonisolated static func systemDefaultInputDeviceID() -> AudioDeviceID? {
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
