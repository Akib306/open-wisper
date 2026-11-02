import Foundation
import Testing
@testable import WisperCore

actor TestGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

@MainActor final class FakeCapture: AudioCapture {
    var starts = 0
    var stops = 0
    var cancellations = 0
    var startGate: TestGate?
    var stopGate: TestGate?
    var failureCallback: (@MainActor @Sendable (UUID, String) -> Void)?
    func start(sessionID: UUID, onFailure: @escaping @MainActor @Sendable (UUID, String) -> Void) async throws {
        starts += 1
        failureCallback = onFailure
        await startGate?.wait()
    }
    func stop(sessionID: UUID) async throws -> RecordedAudio {
        stops += 1
        await stopGate?.wait()
        return RecordedAudio(wavData: Data(), duration: 2)
    }
    func cancel(sessionID: UUID) async { cancellations += 1 }
}

actor FakeTranscriber: Transcriber {
    var calls = 0
    var gate: TestGate?
    let text: String
    init(text: String = "A local transcript.", gate: TestGate? = nil) { self.text = text; self.gate = gate }
    func transcribe(audio: RecordedAudio, profileURL: URL, timeout: TimeInterval) async throws -> TranscriptionResult {
        calls += 1
        await gate?.wait() // Deliberately ignores cancellation to simulate a late worker.
        return TranscriptionResult(text: text, elapsed: 0.25, peakResidentBytes: 64 * 1_024 * 1_024)
    }
}

@MainActor final class FakePermissions: Permissions {
    var gate: TestGate?
    var denied = false
    func requestMicrophoneIfNeeded() async throws {
        await gate?.wait()
        if denied { throw WisperError.message("Microphone access is off.") }
    }
}

@MainActor final class FakeDelivery: Delivery {
    var insertions = 0
    var copies = 0
    var snapshots = 0
    var preparations = 0
    func prepareForDictation() { preparations += 1 }
    var available = true
    var token = TargetToken()
    var deliveredTokens: [TargetToken] = []
    var gate: TestGate?
    func snapshot() -> TargetToken? { snapshots += 1; return available ? token : nil }
    func deliver(_ text: String, to token: TargetToken?) async -> DeliveryResult {
        await gate?.wait()
        guard !Task.isCancelled else { return DeliveryResult(.cancelled, "Cancelled") }
        guard let token else { return DeliveryResult(.blocked, "No target") }
        insertions += 1
        deliveredTokens.append(token)
        return DeliveryResult(.insertionRequested, "Requested")
    }
    func copy(_ text: String) -> Bool { copies += 1; return true }
    func discardTarget() {}
}

@MainActor func eventually(_ predicate: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(3))
    while !predicate() {
        guard clock.now < deadline else { throw WisperError.message("Timed out waiting for a test state.") }
        try await Task.sleep(for: .milliseconds(2))
    }
}

@Suite("Serialized dictation lifecycle") @MainActor
struct SessionCoordinatorTests {
    func configuration(insert: Bool = false, maximum: Double = 300) -> SessionConfiguration {
        SessionConfiguration(profileURL: URL(fileURLWithPath: "/fixture/manifest.json"), maximumDuration: maximum, automaticInsertion: insert)
    }

    @Test func insertionUsesTheCursorAtStopAndNeedsNoReview() async throws {
        let delivery = FakeDelivery()
        let coordinator = SessionCoordinator(capture: FakeCapture(), transcriber: FakeTranscriber(),
                                              permissions: FakePermissions(), delivery: delivery)
        coordinator.start(configuration: configuration(insert: true))
        try await eventually { coordinator.phase == .recording }
        #expect(delivery.snapshots == 0)
        #expect(delivery.preparations == 1)
        let movedCursor = TargetToken()
        delivery.token = movedCursor
        coordinator.stop()
        try await eventually { !coordinator.transcript.isEmpty }
        #expect(delivery.snapshots == 1)
        #expect(delivery.deliveredTokens == [movedCursor])
        #expect(!coordinator.needsReview)
    }

    @Test func reviewOnlySessionsDoNotEnableOtherEditors() async throws {
        let delivery = FakeDelivery()
        let coordinator = SessionCoordinator(capture: FakeCapture(), transcriber: FakeTranscriber(),
                                              permissions: FakePermissions(), delivery: delivery)
        coordinator.start(configuration: configuration(insert: false))
        try await eventually { coordinator.phase == .recording }
        #expect(delivery.preparations == 0)
        coordinator.stop()
        try await eventually { !coordinator.transcript.isEmpty }
    }

    @Test func unavailableTargetKeepsTranscriptForQuietReview() async throws {
        let delivery = FakeDelivery(); delivery.available = false
        let coordinator = SessionCoordinator(capture: FakeCapture(), transcriber: FakeTranscriber(),
                                              permissions: FakePermissions(), delivery: delivery)
        coordinator.start(configuration: configuration(insert: true))
        try await eventually { coordinator.phase == .recording }
        coordinator.stop()
        try await eventually { !coordinator.transcript.isEmpty }
        #expect(delivery.insertions == 0 && delivery.copies == 0)
        #expect(coordinator.deliveryResult?.outcome == .blocked)
        #expect(coordinator.needsReview)
    }

    @Test func cancellationDuringDeliveryCannotPublishOrInsertALateResult() async throws {
        let delivery = FakeDelivery(), gate = TestGate()
        delivery.gate = gate
        let coordinator = SessionCoordinator(capture: FakeCapture(), transcriber: FakeTranscriber(),
                                              permissions: FakePermissions(), delivery: delivery)
        coordinator.start(configuration: configuration(insert: true))
        try await eventually { coordinator.phase == .recording }
        coordinator.stop()
        try await eventually { coordinator.phase == .deliveryPending }
        coordinator.requestCancel()
        await gate.open()
        await coordinator.cancel()
        #expect(delivery.insertions == 0 && coordinator.transcript.isEmpty)
        #expect(!coordinator.needsReview)
    }

    @Test func rapidCommandsFlushAndTranscribeOnce() async throws {
        let capture = FakeCapture(), delivery = FakeDelivery(), permissions = FakePermissions()
        let engine = FakeTranscriber()
        let coordinator = SessionCoordinator(capture: capture, transcriber: engine, permissions: permissions, delivery: delivery)
        var phases: [SessionPhase] = []
        coordinator.onTransition = { phases.append($0) }
        coordinator.start(configuration: configuration())
        coordinator.start(configuration: configuration())
        coordinator.toggle(configuration: configuration())
        try await eventually { coordinator.phase == .recording }
        coordinator.stop(); coordinator.stop(); coordinator.toggle(configuration: configuration())
        try await eventually { coordinator.phase == .idle && !coordinator.transcript.isEmpty }
        #expect(capture.starts == 1 && capture.stops == 1)
        #expect(await engine.calls == 1)
        #expect(phases == [.preparing, .recording, .finalizing, .transcribing, .transforming, .deliveryPending, .completed, .idle])
        #expect(delivery.insertions == 0 && delivery.copies == 0 && delivery.snapshots == 0)
        #expect(coordinator.metrics?.realTimeFactor == 0.125)
        #expect(coordinator.lastTranscriptionMemory?.peakResidentBytes == 64 * 1_024 * 1_024)
        coordinator.copyResult()
        #expect(delivery.copies == 1)
        #expect(coordinator.deliveryResult?.outcome == .copied)
        coordinator.dismissResult()
        #expect(coordinator.transcript.isEmpty && coordinator.metrics == nil)
        #expect(coordinator.lastTranscriptionMemory?.peakResidentBytes == 64 * 1_024 * 1_024)
        coordinator.start(configuration: configuration())
        try await eventually { coordinator.phase == .recording }
        await coordinator.cancel()
        #expect(coordinator.lastTranscriptionMemory?.peakResidentBytes == 64 * 1_024 * 1_024)
    }

    @Test(arguments: [SessionPhase.preparing, .recording, .finalizing, .transcribing, .transforming, .deliveryPending])
    func cancellationRevokesEveryStage(stage: SessionPhase) async throws {
        let capture = FakeCapture(), delivery = FakeDelivery(), permissions = FakePermissions()
        let gate = TestGate()
        if stage == .preparing { permissions.gate = gate }
        if stage == .finalizing { capture.stopGate = gate }
        let engine = FakeTranscriber(gate: stage == .transcribing ? gate : nil)
        let coordinator = SessionCoordinator(capture: capture, transcriber: engine, permissions: permissions,
            delivery: delivery, transform: { text in
                if stage == .transforming { await gate.wait() }
                return text
            })
        if stage == .deliveryPending {
            coordinator.onTransition = { [weak coordinator] phase in
                if phase == .deliveryPending { coordinator?.requestCancel() }
            }
        }
        coordinator.start(configuration: configuration(insert: true))
        if stage != .preparing {
            try await eventually { coordinator.phase == .recording }
            if stage != .recording { coordinator.stop() }
        }
        if stage == .deliveryPending {
            try await eventually { coordinator.phase == .cancelling || coordinator.deliveryResult?.outcome == .cancelled }
        } else {
            try await eventually { coordinator.phase == stage }
            coordinator.requestCancel()
            #expect(coordinator.activeSessionID == nil)
            #expect(coordinator.phase == .cancelling)
        }
        await gate.open()
        await coordinator.cancel()
        try await eventually { coordinator.phase == .idle }
        #expect(coordinator.transcript.isEmpty)
        #expect(delivery.insertions == 0 && delivery.copies == 0)
        #expect(coordinator.deliveryResult?.outcome == .cancelled)
    }

    @Test func staleCaptureFailureCannotCancelNewSession() async throws {
        let capture = FakeCapture(), delivery = FakeDelivery(), permissions = FakePermissions()
        let coordinator = SessionCoordinator(capture: capture, transcriber: FakeTranscriber(), permissions: permissions, delivery: delivery)
        coordinator.start(configuration: configuration())
        let stale = try #require(coordinator.activeSessionID)
        try await eventually { coordinator.phase == .recording }
        await coordinator.cancel()
        coordinator.start(configuration: configuration())
        try await eventually { coordinator.phase == .recording }
        capture.failureCallback?(stale, "late device failure")
        #expect(coordinator.phase == .recording && coordinator.failure == nil)
        await coordinator.shutdown()
        #expect(coordinator.phase == .idle)
    }

    @Test func limitStopsAndDeliversOnlyOnce() async throws {
        let capture = FakeCapture(), delivery = FakeDelivery(), permissions = FakePermissions()
        let coordinator = SessionCoordinator(capture: capture, transcriber: FakeTranscriber(), permissions: permissions, delivery: delivery)
        coordinator.start(configuration: configuration(insert: true, maximum: 0.05))
        try await eventually { !coordinator.transcript.isEmpty }
        #expect(coordinator.automaticallyStopped)
        #expect(capture.stops == 1 && delivery.insertions == 1)
        coordinator.stop()
        #expect(delivery.insertions == 1)
    }

    @Test func deniedPermissionNeverStartsCapture() async throws {
        let capture = FakeCapture(), delivery = FakeDelivery(), permissions = FakePermissions()
        permissions.denied = true
        let coordinator = SessionCoordinator(capture: capture, transcriber: FakeTranscriber(), permissions: permissions, delivery: delivery)
        coordinator.start(configuration: configuration())
        try await eventually { coordinator.failure != nil }
        #expect(coordinator.phase == .idle && capture.starts == 0 && delivery.insertions == 0)
    }

    @Test func quitWaitsForLateInferenceAndPreventsNewSession() async throws {
        let gate = TestGate()
        let capture = FakeCapture(), delivery = FakeDelivery(), permissions = FakePermissions()
        let coordinator = SessionCoordinator(capture: capture, transcriber: FakeTranscriber(gate: gate), permissions: permissions, delivery: delivery)
        coordinator.start(configuration: configuration(insert: true))
        try await eventually { coordinator.phase == .recording }
        coordinator.stop()
        try await eventually { coordinator.phase == .transcribing }
        let shutdown = Task { await coordinator.shutdown() }
        try await eventually { coordinator.phase == .cancelling }
        coordinator.start(configuration: configuration())
        #expect(capture.starts == 1)
        await gate.open()
        await shutdown.value
        #expect(coordinator.phase == .idle && delivery.insertions == 0 && coordinator.transcript.isEmpty)
    }
}
