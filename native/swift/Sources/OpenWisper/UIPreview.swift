import Foundation
import WisperCore

@MainActor enum UIPreview {
    static func session(state: String) async throws -> SessionCoordinator {
        let session = makeSession()
        try await configure(session, state: state)
        return session
    }

    static func makeSession() -> SessionCoordinator {
        SessionCoordinator(capture: PreviewCapture(), transcriber: PreviewTranscriber(),
            permissions: PreviewPermissions(), delivery: PreviewDelivery())
    }

    static func configure(_ session: SessionCoordinator, state: String) async throws {
        guard state != "idle" else { return }
        guard ["recording", "processing", "review", "failure", "cancelled"].contains(state) else {
            throw WisperError.message("Preview state must be idle, recording, processing, review, failure, or cancelled.")
        }
        session.start(configuration: SessionConfiguration(profileURL: URL(fileURLWithPath: "/preview/unused.json"),
            automaticInsertion: false))
        try await wait { session.phase == .recording }
        switch state {
        case "processing", "review": session.stop()
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
    func transcribe(audio: RecordedAudio, profileURL: URL, timeout: TimeInterval) async throws -> TranscriptionResult {
        try await Task.sleep(for: .seconds(2))
        return TranscriptionResult(text: "A little space to speak. Say it naturally. Put your words where you’re already writing.", elapsed: 2)
    }
}

@MainActor private final class PreviewPermissions: Permissions {
    func requestMicrophoneIfNeeded() async throws {}
}

@MainActor private final class PreviewDelivery: Delivery {
    func prepareForDictation() {}
    func snapshot() -> TargetToken? { nil }
    func deliver(_ text: String, to token: TargetToken?) async -> DeliveryResult { DeliveryResult(.blocked, "Preview only. Nothing inserted.") }
    func copy(_ text: String) -> Bool { false }
    func discardTarget() {}
}
