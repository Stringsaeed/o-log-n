import Darwin
import Foundation
import OLogNKit

enum DropzonePresence: String, Codable, CaseIterable, Hashable {
    case always, onDrag, off
}

struct AppSettings: Equatable {
    var engine = EngineSettings()
    var defaultMode = CompressionMode.smart
    var presence = DropzonePresence.onDrag
    var anchor = DropzoneAnchor.rightCenter
    var hotkeyKeyCode: UInt32 = 49
    var hotkeyModifiers: UInt32 = 0x1800
    var launchAtLogin = false
    var haptics = true
    var sound = false
    var historyDays = 7
}

extension AppSettings: Codable {
    private enum Key: String, CodingKey {
        case engine, defaultMode, presence, anchor
        case hotkeyKeyCode, hotkeyModifiers
        case launchAtLogin, haptics, sound, historyDays
    }

    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: Key.self)
        if let engine = try? container.decode(TolerantEngineSettings.self, forKey: .engine) {
            self.engine = engine.settings
        }
        if let value = try? container.decode(CompressionMode.self, forKey: .defaultMode) {
            defaultMode = value
        }
        if let value = try? container.decode(DropzonePresence.self, forKey: .presence) {
            presence = value
        }
        if let value = try? container.decode(DropzoneAnchor.self, forKey: .anchor) {
            anchor = value
        }
        if let value = try? container.decode(UInt32.self, forKey: .hotkeyKeyCode) {
            hotkeyKeyCode = value
        }
        if let value = try? container.decode(UInt32.self, forKey: .hotkeyModifiers) {
            hotkeyModifiers = value
        }
        if let value = try? container.decode(Bool.self, forKey: .launchAtLogin) {
            launchAtLogin = value
        }
        if let value = try? container.decode(Bool.self, forKey: .haptics) {
            haptics = value
        }
        if let value = try? container.decode(Bool.self, forKey: .sound) {
            sound = value
        }
        if let value = try? container.decode(Int.self, forKey: .historyDays) {
            historyDays = value
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(engine, forKey: .engine)
        try container.encode(defaultMode, forKey: .defaultMode)
        try container.encode(presence, forKey: .presence)
        try container.encode(anchor, forKey: .anchor)
        try container.encode(hotkeyKeyCode, forKey: .hotkeyKeyCode)
        try container.encode(hotkeyModifiers, forKey: .hotkeyModifiers)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(haptics, forKey: .haptics)
        try container.encode(sound, forKey: .sound)
        try container.encode(historyDays, forKey: .historyDays)
    }
}

/// Decodes `EngineSettings` one field at a time. A missing or unreadable field keeps that
/// field's default. The engine's synthesized decoder would otherwise reject the whole blob.
private struct TolerantEngineSettings: Decodable {
    var settings: EngineSettings

    private enum Key: String, CodingKey {
        case quality, archiveFormat, imageConversion, output, suffix
        case stripMetadataInSmart, preserveDates, maxCPUJobs, jpegLossless
    }

    init(from decoder: Decoder) throws {
        var settings = EngineSettings()
        let container = try decoder.container(keyedBy: Key.self)
        if let value = try? container.decode(QualityPreset.self, forKey: .quality) {
            settings.quality = value
        }
        if let value = try? container.decode(ArchiveFormat.self, forKey: .archiveFormat) {
            settings.archiveFormat = value
        }
        if let value = try? container.decode(ImageConversion.self, forKey: .imageConversion) {
            settings.imageConversion = value
        }
        if let value = try? container.decode(OutputLocation.self, forKey: .output) {
            settings.output = value
        }
        if let value = try? container.decode(String.self, forKey: .suffix) {
            settings.suffix = value
        }
        if let value = try? container.decode(Bool.self, forKey: .stripMetadataInSmart) {
            settings.stripMetadataInSmart = value
        }
        if let value = try? container.decode(Bool.self, forKey: .preserveDates) {
            settings.preserveDates = value
        }
        if container.contains(.maxCPUJobs), (try? container.decodeNil(forKey: .maxCPUJobs)) != true {
            if let value = try? container.decode(Int.self, forKey: .maxCPUJobs) {
                settings.maxCPUJobs = value
            }
        }
        if let value = try? container.decode(JPEGLosslessStyle.self, forKey: .jpegLossless) {
            settings.jpegLossless = value
        }
        self.settings = settings
    }
}

enum SettingsStorage {
    /// Production uses `UserDefaults.standard`. Selftests install a private suite.
    nonisolated(unsafe) static var defaults: UserDefaults = .standard
    /// Demo mode keeps settings in memory and must not write the user's defaults.
    nonisolated(unsafe) static var persistsWrites = true

    static func load() -> AppSettings {
        guard persistsWrites else { return AppSettings() }
        guard let data = defaults.data(forKey: Logn.defaultsKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return settings
    }

    static func save(_ settings: AppSettings) {
        guard persistsWrites else { return }
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Logn.defaultsKey)
    }
}

enum WorkerBudget {
    /// Same probe the engine uses for its default lane count. Auto must hand the
    /// engine this number explicitly, or a previous manual limit stays in force.
    static var pCoreCount: Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &value, &size, nil, 0) == 0, value > 0 {
            return Int(value)
        }
        return max(1, ProcessInfo.processInfo.activeProcessorCount)
    }
}

extension AppSettings {
    /// A nil worker limit is Auto. The value sent to the engine is the P-core count.
    /// Changing the limit applies to jobs that are still waiting; a job already
    /// running keeps the limit it started with.
    var engineForJobs: EngineSettings {
        var copy = engine
        if copy.maxCPUJobs == nil {
            copy.maxCPUJobs = WorkerBudget.pCoreCount
        }
        return copy
    }
}

@MainActor
@Observable
final class SettingsStore {
    var settings: AppSettings {
        didSet {
            SettingsStorage.save(settings)
            onChange?()
        }
    }

    /// Runtime only. A failed global monitor pins the dropzone for this launch.
    var dragMonitorAvailable = true
    var fallbackNote: String?
    var loginError: String?
    /// `--demo` must not call `SMAppService`.
    var skipLoginItem = false
    var onChange: (@MainActor () -> Void)?

    init() {
        settings = SettingsStorage.load()
    }

    var effectivePresence: DropzonePresence {
        if settings.presence == .onDrag, !dragMonitorAvailable { return .always }
        return settings.presence
    }

    func noteDragUnavailable() {
        guard dragMonitorAvailable else { return }
        dragMonitorAvailable = false
        fallbackNote = "File-drag detection is unavailable, so the dropzone stays pinned. You can still drop files on the Logn menu icon."
        onChange?()
    }

    func resetHotkey() {
        settings.hotkeyKeyCode = 49
        settings.hotkeyModifiers = 0x1800
    }

    func togglePinnedPuck() {
        settings.presence = settings.presence == .always ? .onDrag : .always
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        if skipLoginItem {
            settings.launchAtLogin = enabled
            loginError = nil
            return
        }
        do {
            try LoginItem.setEnabled(enabled)
            settings.launchAtLogin = enabled
            loginError = nil
        } catch {
            if LoginItem.isBenign(error, enabling: enabled) {
                settings.launchAtLogin = enabled
                loginError = nil
                return
            }
            loginError = (error as NSError).localizedDescription
        }
    }

    /// Re-applies a saved preference and surfaces a system refusal inline.
    func syncLoginItem() {
        guard settings.launchAtLogin else { return }
        setLaunchAtLogin(true)
    }
}
