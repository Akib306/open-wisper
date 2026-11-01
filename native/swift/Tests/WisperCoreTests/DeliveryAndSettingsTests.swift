import Foundation
import Testing
@testable import WisperCore

@Suite("Fail-closed delivery policy")
struct DeliveryPolicyTests {
    func context() -> InsertionContext {
        InsertionContext(processID: 123, processStartedAt: Date(timeIntervalSince1970: 10), bundleID: "com.example.editor",
                         role: "AXTextArea", selectionLocation: 5, selectionLength: 0, editable: true, secure: false)
    }
    @Test func onlyUnchangedSupportedTargetIsEligible() {
        let snapshot = context()
        #expect(DeliveryPolicy.blockedReason(snapshot: snapshot, current: snapshot, sameElement: true, ownProcessID: 999, text: "Hello") == nil)
        var alternatives: [InsertionContext] = []
        var changed = snapshot; changed.processStartedAt = Date(); alternatives.append(changed)
        changed = snapshot; changed.processID += 1; alternatives.append(changed)
        changed = snapshot; changed.selectionLocation += 1; alternatives.append(changed)
        changed = snapshot; changed.selectionLength = 3; alternatives.append(changed)
        changed = snapshot; changed.secure = true; alternatives.append(changed)
        changed = snapshot; changed.editable = false; alternatives.append(changed)
        changed = snapshot; changed.bundleID = "com.other.app"; alternatives.append(changed)
        for current in alternatives {
            #expect(DeliveryPolicy.blockedReason(snapshot: snapshot, current: current, sameElement: true, ownProcessID: 999, text: "Hello") != nil)
        }
        #expect(DeliveryPolicy.blockedReason(snapshot: snapshot, current: snapshot, sameElement: false, ownProcessID: 999, text: "Hello") != nil)
        #expect(DeliveryPolicy.blockedReason(snapshot: snapshot, current: snapshot, sameElement: true, ownProcessID: 123, text: "Hello") != nil)
    }
    @Test func secureFieldsTerminalsAndControlCharactersAreBlocked() {
        var current = context()
        current.secure = true
        #expect(DeliveryPolicy.blockedReason(snapshot: current, current: current, sameElement: true, ownProcessID: 999, text: "word") != nil)
        current = context(); current.bundleID = "com.apple.Terminal"
        #expect(DeliveryPolicy.blockedReason(snapshot: current, current: current, sameElement: true, ownProcessID: 999, text: "echo hello\n") != nil)
        current = context()
        #expect(DeliveryPolicy.blockedReason(snapshot: current, current: current, sameElement: true, ownProcessID: 999, text: "word\u{1b}[A") != nil)
        current.role = "AXButton"
        #expect(DeliveryPolicy.blockedReason(snapshot: current, current: current, sameElement: true, ownProcessID: 999, text: "word") != nil)
    }
}

@MainActor final class FakeHotkeys: HotkeyRegistration {
    var combination: HotkeyCombination? = HotkeyCombination()
    var reject: HotkeyCombination?
    func replace(with combination: HotkeyCombination) throws {
        if combination == reject { throw WisperError.message("Shortcut conflict") }
        self.combination = combination
    }
}

@Suite("Atomic settings and shortcut rollback") @MainActor
struct SettingsTests {
    @Test func previewSettingsAdoptCursorInsertionAndLaterOptOutPersists() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("settings-migration-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
        #expect(try store.load().automaticInsertion)
        var legacy = AppSettings()
        legacy.version = 1
        legacy.automaticInsertion = false
        legacy.engineProfilePath = "/custom/profile.json"
        legacy.hotkey = HotkeyCombination(keyCode: 2, modifiers: [.option])
        try JSONEncoder().encode(legacy).write(to: store.fileURL)
        var migrated = try store.load()
        #expect(migrated.version == 2 && migrated.automaticInsertion)
        #expect(migrated.hotkey == legacy.hotkey && migrated.engineProfilePath == legacy.engineProfilePath)
        migrated.automaticInsertion = false
        try store.save(migrated)
        #expect(try !store.load().automaticInsertion)
    }
    @Test func persistenceAndValidation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("settings-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
        #expect(try store.load() == AppSettings())
        var settings = AppSettings(); settings.engineProfilePath = "/path with spaces/profile.json"
        try store.save(settings)
        #expect(try store.load() == settings)
        #expect((try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        settings.maximumDuration = .infinity
        #expect(throws: (any Error).self) { try store.save(settings) }
        #expect(try store.load().maximumDuration == 300)
        var unknown = AppSettings(); unknown.version = 99
        try JSONEncoder().encode(unknown).write(to: store.fileURL)
        #expect(throws: (any Error).self) { try store.load() }
    }
    @Test func failedRegistrationAndPersistencePreservePreviousShortcut() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-rollback-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SettingsStore(fileURL: root.appendingPathComponent("settings.json"))
        let previous = AppSettings()
        try store.save(previous)
        var proposed = previous; proposed.hotkey.keyCode = 2
        let keys = FakeHotkeys(); keys.reject = proposed.hotkey
        #expect(throws: (any Error).self) { try saveSettingsTransaction(proposed, previous: previous, store: store, hotkeys: keys) }
        #expect(keys.combination == previous.hotkey)
        #expect(try store.load() == previous)
        keys.reject = nil
        // A regular file cannot be used as the settings directory.
        let failingStore = SettingsStore(fileURL: store.fileURL.appendingPathComponent("invalid.json"))
        #expect(throws: (any Error).self) { try saveSettingsTransaction(proposed, previous: previous, store: failingStore, hotkeys: keys) }
        #expect(keys.combination == previous.hotkey)
    }
}
