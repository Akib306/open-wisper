import Combine
import Foundation

public enum SessionPhase: String, Codable, Sendable, CaseIterable {
    case idle, preparing, recording, finalizing, transcribing, transforming
    case deliveryPending, completed, cancelling, cancelled, failed

    public var isActive: Bool {
        switch self {
        case .idle, .completed, .cancelled, .failed: false
        default: true
        }
    }

    public var title: String {
        switch self {
        case .idle: "Ready to dictate"
        case .preparing: "Preparing microphone…"
        case .recording: "Listening"
        case .finalizing: "Finishing recording…"
        case .transcribing: "Transcribing on your Mac…"
        case .transforming: "Preparing your words…"
        case .deliveryPending: "Checking destination…"
        case .completed: "Transcript ready"
        case .cancelling: "Cancelling…"
        case .cancelled: "Cancelled"
        case .failed: "Couldn’t finish dictation"
        }
    }
}

public enum DeliveryOutcome: String, Codable, Sendable {
    case reviewReady, copied, insertionRequested, insertionVerified, blocked, cancelled, failed
}

public struct TargetToken: Hashable, Sendable {
    public let id: UUID
    public init(id: UUID = UUID()) { self.id = id }
}

public struct DeliveryResult: Sendable, Equatable {
    public let outcome: DeliveryOutcome
    public let message: String
    public init(_ outcome: DeliveryOutcome, _ message: String) {
        self.outcome = outcome
        self.message = message
    }
}

@MainActor public protocol AudioCapture: AnyObject {
    func start(sessionID: UUID, onFailure: @escaping @MainActor @Sendable (UUID, String) -> Void) async throws
    func stop(sessionID: UUID) async throws -> RecordedAudio
    func cancel(sessionID: UUID) async
}

public protocol Transcriber: Sendable {
    func transcribe(audio: RecordedAudio, profileURL: URL, timeout: TimeInterval) async throws -> TranscriptionResult
}

@MainActor public protocol Permissions: AnyObject {
    func requestMicrophoneIfNeeded() async throws
}

@MainActor public protocol Delivery: AnyObject {
    func prepareForDictation()
    func snapshot() -> TargetToken?
    func deliver(_ text: String, to token: TargetToken?) async -> DeliveryResult
    func copy(_ text: String) -> Bool
    func discardTarget()
}

public struct SessionConfiguration: Sendable {
    public var profileURL: URL
    public var workerTimeout: TimeInterval
    public var maximumDuration: TimeInterval
    public var automaticInsertion: Bool

    public init(profileURL: URL, workerTimeout: TimeInterval = 120,
                maximumDuration: TimeInterval = 300, automaticInsertion: Bool = true) {
        self.profileURL = profileURL
        self.workerTimeout = workerTimeout
        self.maximumDuration = maximumDuration
        self.automaticInsertion = automaticInsertion
    }
}

/// Content-free, monotonic measurements. These are timings, not a resource benchmark.
public struct SessionMetrics: Codable, Sendable {
    public let sessionID: UUID
    public let audioDuration: TimeInterval
    public let inferenceDuration: TimeInterval
    public let stopToReview: TimeInterval
    public let delivery: DeliveryOutcome
    public var realTimeFactor: Double? {
        audioDuration > 0 ? inferenceDuration / audioDuration : nil
    }
}

/// All transitions and delivery authorization are serialized on MainActor.
/// Audio conversion and inference are supplied by independently owned workers.
@MainActor public final class SessionCoordinator: ObservableObject {
    @Published public private(set) var phase: SessionPhase = .idle
    @Published public private(set) var transcript = ""
    @Published public private(set) var deliveryResult: DeliveryResult?
    @Published public private(set) var failure: String?
    @Published public private(set) var metrics: SessionMetrics?
    @Published public private(set) var lastTranscriptionMemory: TranscriptionMemory?
    @Published public private(set) var automaticallyStopped = false
    @Published public private(set) var recordingStartedAt: Date?
    public private(set) var activeSessionID: UUID?

    public var needsReview: Bool {
        !phase.isActive && (failure != nil || (!transcript.isEmpty &&
            deliveryResult?.outcome != .insertionRequested && deliveryResult?.outcome != .insertionVerified))
    }

    public var onTransition: (@MainActor (SessionPhase) -> Void)?
    private let capture: any AudioCapture
    private let transcriber: any Transcriber
    private let permissions: any Permissions
    private let delivery: any Delivery
    private let transform: @Sendable (String) async throws -> String
    private var configuration: SessionConfiguration?
    private var target: TargetToken?
    private var operation: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var durationLimit: Task<Void, Never>?
    private var deliveryAuthorized = false

    public init(capture: any AudioCapture, transcriber: any Transcriber,
                permissions: any Permissions, delivery: any Delivery,
                transform: @escaping @Sendable (String) async throws -> String = { $0 }) {
        self.capture = capture
        self.transcriber = transcriber
        self.permissions = permissions
        self.delivery = delivery
        self.transform = transform
    }

    public func toggle(configuration: SessionConfiguration) {
        if phase == .recording { stop() }
        else if !phase.isActive { start(configuration: configuration) }
    }

    public func start(configuration: SessionConfiguration) {
        guard !phase.isActive else { return }
        guard configuration.maximumDuration.isFinite, (0.05...300).contains(configuration.maximumDuration),
              configuration.workerTimeout.isFinite, (0.05...600).contains(configuration.workerTimeout) else {
            failure = "Recording duration or worker timeout is outside its supported range."
            return
        }
        let id = UUID()
        activeSessionID = id
        self.configuration = configuration
        transcript = ""
        deliveryResult = nil
        metrics = nil
        failure = nil
        automaticallyStopped = false
        deliveryAuthorized = true
        target = nil
        delivery.discardTarget()
        transition(.preparing)
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try await permissions.requestMicrophoneIfNeeded()
                guard isCurrent(id) else { return }
                try Task.checkCancellation()
                if configuration.automaticInsertion { delivery.prepareForDictation() }
                try await capture.start(sessionID: id) { [weak self] sessionID, message in
                    self?.captureFailed(sessionID: sessionID, message: message)
                }
                guard isCurrent(id) else {
                    await capture.cancel(sessionID: id)
                    return
                }
                recordingStartedAt = Date()
                transition(.recording)
                guard isCurrent(id) else { return }
                durationLimit = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(configuration.maximumDuration)) }
                    catch { return }
                    guard let self, self.isCurrent(id), self.phase == .recording else { return }
                    self.automaticallyStopped = true
                    self.stop()
                }
            } catch {
                await finishFailure(error, sessionID: id)
            }
        }
    }

    public func prepareDeliveryForFrontmostApp() {
        guard phase == .recording, configuration?.automaticInsertion == true else { return }
        delivery.prepareForDictation()
    }

    public func stop() {
        guard phase == .recording, let id = activeSessionID, let configuration else { return }
        // Users may move their cursor while speaking. Freeze the destination at
        // Stop, before finalization/inference, then revalidate it before writing.
        target = configuration.automaticInsertion ? delivery.snapshot() : nil
        durationLimit?.cancel()
        durationLimit = nil
        let stoppedAt = ContinuousClock.now
        transition(.finalizing)
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let audio = try await capture.stop(sessionID: id)
                // Release adapter caches and hardware ownership before inference.
                await capture.cancel(sessionID: id)
                guard isCurrent(id) else { return }
                try Task.checkCancellation()
                transition(.transcribing)
                let raw = try await transcriber.transcribe(audio: audio, profileURL: configuration.profileURL,
                                                           timeout: configuration.workerTimeout)
                guard isCurrent(id) else { return }
                try Task.checkCancellation()
                lastTranscriptionMemory = TranscriptionMemory(peakResidentBytes: raw.peakResidentBytes)
                transition(.transforming)
                let text = try await transform(raw.text).trimmingCharacters(in: .whitespacesAndNewlines)
                guard isCurrent(id) else { return }
                try Task.checkCancellation()
                guard !text.isEmpty else { throw WisperError.message("No speech was recognized. Try again closer to the microphone.") }
                transition(.deliveryPending)
                // A cancellation queued by any phase observer gets a chance to revoke delivery.
                await Task.yield()
                guard isCurrent(id), deliveryAuthorized else { return }
                try Task.checkCancellation()
                deliveryAuthorized = false // Consume once BEFORE any platform side effect.
                let result: DeliveryResult
                if configuration.automaticInsertion {
                    result = await delivery.deliver(text, to: target)
                } else {
                    result = DeliveryResult(.reviewReady, "Review your transcript, then copy it when you’re ready.")
                }
                guard isCurrent(id) else { return }
                try Task.checkCancellation()
                transcript = text
                deliveryResult = result
                metrics = SessionMetrics(sessionID: id, audioDuration: audio.duration, inferenceDuration: raw.elapsed,
                                         stopToReview: stoppedAt.duration(to: .now).seconds, delivery: result.outcome)
                finish(.completed)
            } catch {
                await finishFailure(error, sessionID: id)
            }
        }
    }

    public func recordingLimitReached(sessionID: UUID) {
        guard isCurrent(sessionID), phase == .recording else { return }
        automaticallyStopped = true
        stop()
    }

    public func requestCancel() {
        guard phase.isActive, phase != .cancelling, let id = activeSessionID else { return }
        let previousOperation = operation
        revoke()
        transition(.cancelling)
        previousOperation?.cancel()
        cleanup = Task { [weak self] in
            guard let self else { return }
            await capture.cancel(sessionID: id)
            // Do not allow a new worker before the cancelled worker has been reaped.
            await previousOperation?.value
            transcript = ""
            deliveryResult = DeliveryResult(.cancelled, "Dictation cancelled.")
            finish(.cancelled)
            cleanup = nil
        }
    }

    public func cancel() async {
        requestCancel()
        if let cleanup { await cleanup.value }
        else if phase == .cancelling { await operation?.value }
    }

    public func dismissResult() {
        guard !phase.isActive else { return }
        transcript = ""
        metrics = nil
        failure = nil
        deliveryResult = nil
        automaticallyStopped = false
        delivery.discardTarget()
    }

    public func copyResult() {
        guard !phase.isActive, !transcript.isEmpty else { return }
        deliveryResult = delivery.copy(transcript)
            ? DeliveryResult(.copied, "Copied. Other apps can read text on the clipboard.")
            : DeliveryResult(.failed, "Couldn’t copy the transcript. Select the text and copy it manually.")
    }

    public func captureFailed(sessionID: UUID, message: String) {
        guard isCurrent(sessionID), phase != .cancelling else { return }
        let previousOperation = operation
        revoke()
        transition(.cancelling)
        previousOperation?.cancel()
        cleanup = Task { [weak self] in
            guard let self else { return }
            await capture.cancel(sessionID: sessionID)
            await previousOperation?.value
            failure = message
            finish(.failed)
            cleanup = nil
        }
    }

    /// Cancels capture/inference and waits for their cleanup before app termination.
    public func shutdown() async {
        await cancel()
        dismissResult()
    }

    private func isCurrent(_ id: UUID) -> Bool { activeSessionID == id && phase != .cancelling }

    private func revoke() {
        deliveryAuthorized = false
        activeSessionID = nil
        target = nil
        durationLimit?.cancel()
        durationLimit = nil
        delivery.discardTarget()
    }

    private func finishFailure(_ error: Error, sessionID: UUID) async {
        guard isCurrent(sessionID) else { return }
        // Keep a terminal cleanup phase until capture is fully released.
        revoke()
        transition(.cancelling)
        await capture.cancel(sessionID: sessionID)
        if error is CancellationError {
            deliveryResult = DeliveryResult(.cancelled, "Dictation cancelled.")
            finish(.cancelled)
        } else {
            failure = error.localizedDescription
            finish(.failed)
        }
    }

    private func finish(_ terminal: SessionPhase) {
        revoke()
        recordingStartedAt = nil
        transition(terminal)
        transition(.idle)
    }

    private func transition(_ next: SessionPhase) {
        phase = next
        onTransition?(next)
    }
}

private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
