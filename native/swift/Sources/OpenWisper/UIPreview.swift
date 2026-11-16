import Foundation
import WisperCore

@MainActor enum UIPreview {
    static func configureEngine(_ model: AppModel, state: String) throws {
        switch state {
        case "ready": break
        case "missing", "checking", "failed":
            model.engineReady = false
            model.checkingEngine = state == "checking"
            model.engineDescription = state == "checking" ? "Verifying engine and model…" :
                state == "missing" ? "Choose a local engine profile to get started." :
                "The selected engine profile is unavailable. Choose another profile and verify it."
        default: throw WisperError.message("Preview engine must be ready, missing, checking, or failed.")
        }
    }

    static func session(state: String) async throws -> SessionCoordinator {
        let session = makeSession(copySucceeds: state != "copy-failed", longTranscript: state == "long-review")
        try await configure(session, state: state)
        return session
    }

    static func makeSession(copySucceeds: Bool = true, longTranscript: Bool = false) -> SessionCoordinator {
        SessionCoordinator(capture: PreviewCapture(), transcriber: PreviewTranscriber(longTranscript: longTranscript),
            permissions: PreviewPermissions(), delivery: PreviewDelivery(copySucceeds: copySucceeds))
    }

    static func configure(_ session: SessionCoordinator, state: String) async throws {
        guard state != "idle" else { return }
        guard ["recording", "processing", "review", "long-review", "copied", "copy-failed", "failure", "cancelled"].contains(state) else {
            throw WisperError.message("Preview state must be idle, recording, processing, review, long-review, copied, copy-failed, failure, or cancelled.")
        }
        session.start(configuration: SessionConfiguration(profileURL: URL(fileURLWithPath: "/preview/unused.json"),
            automaticInsertion: false))
        try await wait { session.phase == .recording }
        switch state {
        case "processing", "review", "long-review", "copied", "copy-failed": session.stop()
        case "failure":
            if let id = session.activeSessionID { session.captureFailed(sessionID: id, message: "Preview interruption. No audio was recorded.") }
        case "cancelled": await session.cancel()
        default: break
        }
        if state == "processing" {
            try await wait { session.phase == .transcribing }
        } else if state != "recording" {
            try await wait { !session.phase.isActive }
        }
        if state == "copied" || state == "copy-failed" { session.copyResult() }
    }

    private static func wait(until predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw WisperError.message("UI preview state timed out.") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

@MainActor private final class PreviewCapture: AudioCapture {
    func start(sessionID: UUID, onFailure: @escaping @MainActor @Sendable (UUID, String) -> Void) async throws {}
    func stop(sessionID: UUID) async throws -> RecordedAudio { RecordedAudio(wavData: Data(), duration: 12) }
    func cancel(sessionID: UUID) async {}
}

private struct PreviewTranscriber: Transcriber {
    let longTranscript: Bool

    func transcribe(audio: RecordedAudio, profileURL: URL, timeout: TimeInterval) async throws -> TranscriptionResult {
        try await Task.sleep(for: .seconds(2))
        let sample = "This is a sample transcript for UI testing. No audio was recorded."
        return TranscriptionResult(text: longTranscript ? Array(repeating: sample, count: 60).joined(separator: "\n\n") : sample, elapsed: 2)
    }
}

@MainActor private final class PreviewPermissions: Permissions {
    func requestMicrophoneIfNeeded() async throws {}
}

@MainActor private final class PreviewDelivery: Delivery {
    let copySucceeds: Bool
    init(copySucceeds: Bool) { self.copySucceeds = copySucceeds }
    func prepareForDictation() {}
    func snapshot() -> TargetToken? { nil }
    func deliver(_ text: String, to token: TargetToken?) async -> DeliveryResult { DeliveryResult(.blocked, "Preview only. Nothing inserted.") }
    func copy(_ text: String) -> Bool { copySucceeds }
    func discardTarget() {}
}
