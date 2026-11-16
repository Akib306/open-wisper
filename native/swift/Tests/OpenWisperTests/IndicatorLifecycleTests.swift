import AppKit
import Foundation
import Testing
import WisperCore
@testable import OpenWisper

@Suite("Pill and review synchronization", .serialized) @MainActor
struct IndicatorLifecycleTests {
    @Test(arguments: [true, false])
    func reviewCopyAndCloseUpdateThePill(copySucceeds: Bool) async throws {
        let session = session(copySucceeds: copySucceeds)
        let delegate = AppDelegate(model: AppModel(preview: true, previewSession: session))
        session.start(configuration: configuration())
        try await wait { session.phase == .recording }
        session.stop()
        try await wait { delegate.indicatorFeedback == .review }

        session.copyResult()
        try await wait { delegate.indicatorFeedback == (copySucceeds ? .copied : .review) }
        #expect(session.deliveryResult?.outcome == (copySucceeds ? .copied : .copyFailed))
        #expect(!session.transcript.isEmpty)

        delegate.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        try await wait { delegate.indicatorFeedback == .hidden }
        #expect(session.transcript.isEmpty)
        await session.shutdown()
    }

    @Test func oldCompletionTimerCannotHideANewRecording() async throws {
        let session = session(copySucceeds: true)
        let delegate = AppDelegate(model: AppModel(preview: true, previewSession: session))
        session.start(configuration: configuration(automaticInsertion: true))
        try await wait { session.phase == .recording }
        session.stop()
        try await wait { delegate.indicatorFeedback == .insertionRequested }

        session.start(configuration: configuration())
        try await wait { session.phase == .recording }
        try await Task.sleep(for: .seconds(1.9))
        #expect(delegate.indicatorFeedback == .active)
        await session.shutdown()
        try await wait { delegate.indicatorFeedback == .hidden }
    }

    @Test func copyConfirmationDismissesWithoutClearingTheTranscript() async throws {
        let session = session(copySucceeds: true)
        let delegate = AppDelegate(model: AppModel(preview: true, previewSession: session))
        session.start(configuration: configuration())
        try await wait { session.phase == .recording }
        session.stop()
        try await wait { delegate.indicatorFeedback == .review }
        session.copyResult()
        try await wait { delegate.indicatorFeedback == .copied }
        try await wait(timeout: .seconds(5)) { delegate.indicatorFeedback == .hidden }
        #expect(!session.transcript.isEmpty)
        await session.shutdown()
    }

    private func session(copySucceeds: Bool) -> SessionCoordinator {
        SessionCoordinator(capture: PillCapture(), transcriber: PillTranscriber(),
            permissions: PillPermissions(), delivery: PillDelivery(copySucceeds: copySucceeds))
    }

    private func configuration(automaticInsertion: Bool = false) -> SessionConfiguration {
        SessionConfiguration(profileURL: URL(fileURLWithPath: "/fixture/unused.json"),
            automaticInsertion: automaticInsertion)
    }

    private func wait(timeout: Duration = .seconds(2), until predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw WisperError.message("Pill state did not settle.") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

@MainActor private final class PillCapture: AudioCapture {
    func start(sessionID: UUID, onFailure: @escaping @MainActor @Sendable (UUID, String) -> Void) async throws {}
    func stop(sessionID: UUID) async throws -> RecordedAudio { RecordedAudio(wavData: Data(), duration: 1) }
    func cancel(sessionID: UUID) async {}
}

private struct PillTranscriber: Transcriber {
    func transcribe(audio: RecordedAudio, profileURL: URL, timeout: TimeInterval) async throws -> TranscriptionResult {
        TranscriptionResult(text: "Fixture transcript", elapsed: 0)
    }
}

@MainActor private final class PillPermissions: Permissions {
    func requestMicrophoneIfNeeded() async throws {}
}

@MainActor private final class PillDelivery: Delivery {
    let copySucceeds: Bool
    init(copySucceeds: Bool) { self.copySucceeds = copySucceeds }
    func prepareForDictation() {}
    func snapshot() -> TargetToken? { TargetToken() }
    func deliver(_ text: String, to token: TargetToken?) async -> DeliveryResult {
        DeliveryResult(.insertionRequested, "Fixture insertion request")
    }
    func copy(_ text: String) -> Bool { copySucceeds }
    func discardTarget() {}
}
