import Foundation

public struct HotkeyModifiers: OptionSet, Codable, Sendable, Equatable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let command = Self(rawValue: 1)
    public static let shift = Self(rawValue: 2)
    public static let option = Self(rawValue: 4)
    public static let control = Self(rawValue: 8)
}

public struct HotkeyCombination: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: HotkeyModifiers
    public init(keyCode: UInt32 = 49, modifiers: HotkeyModifiers = [.command, .shift]) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
    public static let supportedKeys: [(code: UInt32, name: String)] = [
        (49, "Space"), (2, "D"), (9, "V"), (17, "T"), (1, "S"), (40, "K"), (37, "L")
    ]
    public var displayName: String {
        let key = Self.supportedKeys.first { $0.code == keyCode }?.name ?? "Key \(keyCode)"
        return (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "")
            + (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "") + " " + key
    }
    public func validate() throws {
        guard Self.supportedKeys.contains(where: { $0.code == keyCode }),
              modifiers.rawValue & ~UInt32(15) == 0,
              !modifiers.intersection([.command, .control, .option]).isEmpty else {
            throw WisperError.message("Choose a supported shortcut with Command, Control, or Option.")
        }
    }
}

public enum WhisperModel: String, Codable, Sendable, CaseIterable {
    case tiny = "tiny.en-q5_1"
    case base = "base.en"
    case small = "small.en"
    case custom
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var version = 2
    public var engineProfilePath = ""
    public var whisperModel: WhisperModel?
    public var hotkey = HotkeyCombination()
    public var automaticInsertion = true
    public var workerTimeout: TimeInterval = 120
    public var maximumDuration: TimeInterval = 300

    public init() {}

    public mutating func resolveModelProfile(resources: URL?) {
        if whisperModel == nil {
            whisperModel = engineProfilePath.isEmpty || engineProfilePath.hasSuffix(".app/Contents/Resources/engine-profile.json") ? .base : .custom
        }
        guard let model = whisperModel, model != .custom else { return }
        engineProfilePath = resources?.appendingPathComponent("engine-profile-\(model.rawValue).json").path ?? ""
    }

    /// Bundled profiles move with the app; custom external profiles keep their paths.
    public mutating func resolveBundledProfile(_ bundledURL: URL?) {
        guard let bundledURL else { return }
        if engineProfilePath.isEmpty || engineProfilePath.hasSuffix(".app/Contents/Resources/engine-profile.json") {
            engineProfilePath = bundledURL.path
        }
    }

    public func validate() throws {
        guard version == 2 else { throw WisperError.message("These settings were created by a different app version. Keep a backup before replacing them.") }
        guard engineProfilePath.isEmpty || (engineProfilePath.hasPrefix("/") && !engineProfilePath.contains("\0")) else {
            throw WisperError.message("Choose an engine profile using an absolute file path.")
        }
        guard workerTimeout.isFinite, (5...600).contains(workerTimeout),
              maximumDuration.isFinite, (1...300).contains(maximumDuration) else {
            throw WisperError.message("Use a recording limit of 1–300 seconds and a worker timeout of 5–600 seconds.")
        }
        try hotkey.validate()
    }
}

public struct SettingsStore: Sendable {
    public let fileURL: URL
    public init(fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/dev.akib.openwisper.swift/settings.json")) {
        self.fileURL = fileURL
    }

    public func load() throws -> AppSettings {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return AppSettings() }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 64 * 1024 else {
            throw WisperError.message("Settings must be a regular JSON file smaller than 64 KiB.")
        }
        var settings = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: fileURL))
        if settings.version == 1 {
            // The development preview defaulted to review-only. Adopt the
            // requested cursor-delivery workflow while preserving engine/hotkey
            // choices. A version-2 explicit opt-out remains respected.
            settings.version = 2
            settings.automaticInsertion = true
        }
        try settings.validate()
        return settings
    }

    public func save(_ settings: AppSettings) throws {
        try settings.validate()
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

@MainActor public protocol HotkeyRegistration: AnyObject {
    var combination: HotkeyCombination? { get }
    func replace(with combination: HotkeyCombination) throws
}

/// Registration is replaced before persistence; failed persistence rolls it back.
@MainActor public func saveSettingsTransaction(_ proposed: AppSettings, previous: AppSettings,
                                               store: SettingsStore, hotkeys: any HotkeyRegistration) throws {
    try proposed.validate()
    let changed = proposed.hotkey != previous.hotkey || hotkeys.combination == nil
    if changed { try hotkeys.replace(with: proposed.hotkey) }
    do { try store.save(proposed) }
    catch {
        if changed {
            do { try hotkeys.replace(with: previous.hotkey) }
            catch { throw WisperError.message("Settings could not be saved and the previous shortcut could not be restored. Choose an available shortcut and try again.") }
        }
        throw error
    }
}
