import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers
import WisperCore
import WisperPlatform

extension AVAudioCapture: AudioCapture {}
extension WhisperTranscriber: Transcriber {}

@MainActor final class AppModel: ObservableObject {
    let coordinator: SessionCoordinator
    let permissions: PermissionsService
    let store: SettingsStore
    let capture: AVAudioCapture
    private(set) var hotkeys: GlobalHotkey?
    @Published var settings: AppSettings
    @Published var settingsOpen = false
    @Published var notice: String?
    @Published var engineDescription = "Choose a local engine profile to get started."
    @Published var engineReady = false
    @Published var checkingEngine = false
    @Published var permissionRefresh = 0
    var onPhase: ((SessionPhase) -> Void)?
    var onNeedsWindow: (() -> Void)?
    private var settingsWritable = true
    private var verification: Task<Void, Never>?
    private var hashVerification: Task<String, Error>?
    private var settingsGeneration = UUID()

    init(profileURL: URL? = nil, preview: Bool = false) {
        let store = SettingsStore()
        self.store = store
        var initial = AppSettings()
        var loadError: String?
        do { initial = try store.load() }
        catch { loadError = "Settings could not be loaded. Your file has been preserved. \(error.localizedDescription)" }
        if let profileURL { initial.engineProfilePath = profileURL.path; initial.whisperModel = .custom }
        else { initial.resolveModelProfile(resources: Bundle.main.resourceURL) }
        self.settings = initial
        self.notice = loadError
        self.settingsWritable = loadError == nil
        let permissions = PermissionsService()
        self.permissions = permissions
        let capture = AVAudioCapture()
        self.capture = capture
        self.coordinator = SessionCoordinator(capture: capture, transcriber: WhisperTranscriber(),
                                              permissions: permissions, delivery: AccessibilityDelivery())
        capture.onDurationLimit = { [weak coordinator] id in coordinator?.recordingLimitReached(sessionID: id) }
        coordinator.onTransition = { [weak self] phase in
            self?.objectWillChange.send()
            self?.onPhase?(phase)
        }
        if !preview {
            do {
                let hotkeys = try GlobalHotkey()
                self.hotkeys = hotkeys
                hotkeys.onPress = { [weak self] in self?.toggle() }
                try hotkeys.replace(with: initial.hotkey)
            } catch { self.notice = error.localizedDescription }
            verifyEngine()
            Task { [weak self] in
                do { _ = try await Task.detached(priority: .utility) { try WhisperTranscriber.recoverStaleSessions() }.value }
                catch { self?.notice = "Some old temporary audio could not be safely cleaned up. See the Swift README’s recovery instructions." }
            }
        }
    }

    var shortcutLabel: String { hotkeys?.combination?.displayName ?? settings.hotkey.displayName }

    func toggle() {
        if coordinator.phase == .recording { coordinator.stop(); return }
        guard !coordinator.phase.isActive else { return }
        guard engineReady else {
            notice = "Choose and verify an engine profile in Settings before recording."
            settingsOpen = true
            onNeedsWindow?()
            return
        }
        notice = nil
        coordinator.start(configuration: SessionConfiguration(profileURL: URL(fileURLWithPath: settings.engineProfilePath),
                                                               workerTimeout: settings.workerTimeout,
                                                               maximumDuration: settings.maximumDuration,
                                                               automaticInsertion: settings.automaticInsertion))
    }

    func cancel() { coordinator.requestCancel() }

    func save(_ proposed: AppSettings) {
        guard !coordinator.phase.isActive else { notice = "Finish dictation before changing settings."; return }
        guard settingsWritable else { notice = "The existing settings file could not be read. Reveal it and move it aside before restarting; it has not been overwritten."; return }
        do {
            if let hotkeys {
                try saveSettingsTransaction(proposed, previous: settings, store: store, hotkeys: hotkeys)
            } else {
                try store.save(proposed)
            }
            let profileChanged = proposed.engineProfilePath != settings.engineProfilePath
            settings = proposed
            notice = nil
            if profileChanged { verifyEngine() }
        } catch { notice = error.localizedDescription }
    }

    func chooseProfile() {
        let picker = NSOpenPanel()
        picker.title = "Choose a local engine profile"
        picker.prompt = "Use Profile"
        picker.allowedContentTypes = [.json]
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let url = picker.url else { return }
        var updated = settings
        updated.engineProfilePath = url.path
        updated.whisperModel = .custom
        save(updated)
    }

    func chooseModel(_ model: WhisperModel) {
        if model == .custom { chooseProfile(); return }
        var updated = settings
        updated.whisperModel = model
        updated.resolveModelProfile(resources: Bundle.main.resourceURL)
        save(updated)
    }

    func verifyEngine() {
        verification?.cancel()
        hashVerification?.cancel()
        engineReady = false
        guard !settings.engineProfilePath.isEmpty else {
            engineDescription = "Choose a local engine profile to get started."
            return
        }
        let url = URL(fileURLWithPath: settings.engineProfilePath)
        let generation = UUID()
        settingsGeneration = generation
        checkingEngine = true
        engineDescription = "Verifying engine and model…"
        let hashTask = Task.detached(priority: .utility) {
            try EngineProfileCheck.check(url)
        }
        hashVerification = hashTask
        verification = Task { [weak self] in
            do {
                // Hash verification runs off the main actor. The worker also
                // revalidates the profile immediately before every invocation.
                let description = try await hashTask.value
                guard let self, self.settingsGeneration == generation, !Task.isCancelled else { return }
                self.engineDescription = description
                self.engineReady = true
                self.checkingEngine = false
            } catch {
                guard let self, self.settingsGeneration == generation, !Task.isCancelled else { return }
                self.engineDescription = error.localizedDescription
                self.checkingEngine = false
            }
        }
    }

    func refreshPermissions() { permissionRefresh += 1 }

    func revealSettings() {
        NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
    }

    func shutdown() async {
        hotkeys?.invalidate()
        verification?.cancel()
        hashVerification?.cancel()
        await coordinator.shutdown()
    }
}
