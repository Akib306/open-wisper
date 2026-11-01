import AppKit
import AVFoundation
import CoreAudio
import CWisperAudio
import Foundation
import WisperCore

/// Main-actor facade. The caller owns microphone authorization and visible
/// recording state. This adapter never requests permission or resumes a changed
/// device automatically. Await cancel before considering capture cleaned up.
@MainActor
public final class AVAudioCapture {
    /// Mono RMS in [0, 1], delivered at most ten times per second, with session ID.
    public var onLevel: (@MainActor @Sendable (UUID, Float) -> Void)?
    /// The hard frame bound stops hardware even if the UI timer was delayed.
    public var onDurationLimit: (@MainActor @Sendable (UUID) -> Void)?

    private let worker: AudioCaptureWorker
    private var request: Request?

    public init() {
        worker = AudioCaptureWorker(workspaceNotifications: NSWorkspace.shared.notificationCenter)
    }

    deinit { worker.shutdown() }

    public func start(sessionID: UUID,
                      onFailure: @escaping @MainActor @Sendable (UUID, String) -> Void) async throws {
        if let previous = request {
            if let cancellation = previous.cancellation {
                await cancellation.value
            } else if !previous.ended {
                guard previous.token.sessionID == sessionID else {
                    throw WisperError.message("Another recording is already active.")
                }
                try await previous.start.value
                if previous.cancelled { throw CancellationError() }
                if let failure = previous.failure { throw WisperError.message(failure) }
                return
            }
        }
        // Query only. Checking first also avoids an accidental prompt caused by
        // constructing/starting input hardware before the app's permission flow.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw WisperError.message("Microphone access is required before starting a recording.")
        }
        let token = AudioCaptureToken(sessionID: sessionID, generation: UUID())
        let worker = worker
        let begin = Task {
            try Task.checkCancellation()
            try await worker.start(token: token, onFailure: { [weak self] message in
                guard let self, let current = self.request,
                      current.token == token, !current.cancelled, !current.ended else { return }
                current.failure = message
                current.ended = true
                onFailure(sessionID, message)
            }, onLevel: { [weak self] level in
                guard let self, let current = self.request,
                      current.token == token, !current.cancelled, !current.ended else { return }
                self.onLevel?(sessionID, level)
            }, onLimit: { [weak self] in
                guard let self, let current = self.request,
                      current.token == token, !current.cancelled else { return }
                self.onDurationLimit?(sessionID)
            })
            try Task.checkCancellation()
        }
        let current = Request(token: token, start: begin)
        request = current
        do {
            try await begin.value
            if current.cancelled { throw CancellationError() }
            if let failure = current.failure { throw WisperError.message(failure) }
        } catch {
            current.ended = true
            throw error
        }
    }

    public func stop(sessionID: UUID) async throws -> RecordedAudio {
        guard let current = request, current.token.sessionID == sessionID else {
            throw WisperError.message("There is no matching recording to stop.")
        }
        if current.cancelled { throw CancellationError() }
        let stop: Task<RecordedAudio, Error>
        if let existing = current.stop {
            stop = existing
        } else {
            let worker = worker
            let token = current.token
            let begin = current.start
            stop = Task {
                try await begin.value
                try Task.checkCancellation()
                return try await worker.stop(token: token)
            }
            current.stop = stop
        }
        defer { current.ended = true }
        let audio = try await stop.value
        if current.cancelled { throw CancellationError() }
        return audio
    }

    public func cancel(sessionID: UUID) async {
        guard let current = request, current.token.sessionID == sessionID else { return }
        if let cancellation = current.cancellation {
            await cancellation.value
            return
        }
        current.cancelled = true
        current.start.cancel()
        current.stop?.cancel()
        let worker = worker
        let token = current.token
        let cancellation = Task { await worker.cancel(token: token) }
        current.cancellation = cancellation
        await cancellation.value
        current.ended = true
        if request === current { request = nil }
    }

    private final class Request {
        let token: AudioCaptureToken
        let start: Task<Void, Error>
        var stop: Task<RecordedAudio, Error>?
        var cancellation: Task<Void, Never>?
        var cancelled = false
        var ended = false
        var failure: String?

        init(token: AudioCaptureToken, start: Task<Void, Error>) {
            self.token = token
            self.start = start
        }
    }
}

private struct AudioCaptureToken: Sendable, Equatable {
    let sessionID: UUID
    let generation: UUID
}

/// The pointer never changes. C owns all synchronization; exactly one tap
/// produces and one capture queue consumes. A fresh handle is allocated for
/// every generation. Tap/notification closures retain this handle (not their
/// borrowed AVAudioPCMBuffer), keeping even a late callback memory-safe after
/// close. Destruction runs only after all these owners release the handle.
private final class AudioRingHandle: @unchecked Sendable {
    let pointer: OpaquePointer

    init(channels: UInt32, maximumFrames: UInt64) throws {
        guard let pointer = wisper_audio_ring_create(65_536, channels, maximumFrames) else {
            throw WisperError.message("Unable to allocate a lock-free microphone buffer.")
        }
        self.pointer = pointer
    }

    deinit { wisper_audio_ring_destroy(pointer) }
}

/// Narrow queue-owned Sendable bridge. Every mutable field, AVAudioEngine,
/// converter and scratch buffer is accessed solely on `queue`; async entry
/// points submit work there. The only objects shared with framework callbacks
/// are immutable tokens and AudioRingHandle's C-atomic interface.
private final class AudioCaptureWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.openwisper.capture", qos: .userInitiated)
    private let workspaceNotifications: NotificationCenter
    private var session: AudioCaptureSession?
    private var lastCompletion: (AudioCaptureToken, Result<RecordedAudio, Error>)?

    init(workspaceNotifications: NotificationCenter) {
        self.workspaceNotifications = workspaceNotifications
    }

    func start(token: AudioCaptureToken,
               onFailure: @escaping @MainActor @Sendable (String) -> Void,
               onLevel: @escaping @MainActor @Sendable (Float) -> Void,
               onLimit: @escaping @MainActor @Sendable () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.begin(token: token, onFailure: onFailure, onLevel: onLevel, onLimit: onLimit)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func stop(token: AudioCaptureToken) async throws -> RecordedAudio {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let session = self.session, session.token == token else {
                    if let previous = self.lastCompletion, previous.0 == token {
                        continuation.resume(with: previous.1)
                    } else {
                        continuation.resume(throwing: WisperError.message("The recording session is no longer active."))
                    }
                    return
                }
                session.stops.append(continuation)
                self.stopHardware(session)
                self.completeWhenIdle(token: token)
            }
        }
    }

    func cancel(token: AudioCaptureToken) async {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let session = self.session, session.token == token else {
                    if self.lastCompletion?.0 == token { self.lastCompletion = nil }
                    continuation.resume()
                    return
                }
                session.cancelled = true
                session.cancellations.append(continuation)
                self.stopHardware(session)
                self.completeWhenIdle(token: token)
            }
        }
    }

    func shutdown() {
        queue.async {
            self.lastCompletion = nil
            guard let session = self.session else { return }
            session.cancelled = true
            self.stopHardware(session)
            self.completeWhenIdle(token: session.token)
        }
    }

    private func begin(token: AudioCaptureToken,
                       onFailure: @escaping @MainActor @Sendable (String) -> Void,
                       onLevel: @escaping @MainActor @Sendable (Float) -> Void,
                       onLimit: @escaping @MainActor @Sendable () -> Void) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard session == nil else { throw WisperError.message("The previous recording is still cleaning up.") }
        lastCompletion = nil
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw WisperError.message("Microphone access is no longer authorized.")
        }
        let device = try defaultInputDevice()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardware = input.outputFormat(forBus: 0)
        guard hardware.sampleRate.isFinite, (8_000...192_000).contains(hardware.sampleRate),
              (1...32).contains(hardware.channelCount),
              let format = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate,
                                         channels: hardware.channelCount) else {
            throw WisperError.message("The selected microphone has no supported audio format.")
        }
        let ring = try AudioRingHandle(channels: format.channelCount,
                                       maximumFrames: UInt64((format.sampleRate * PCM16AudioConverter.maximumDuration).rounded(.down)))
        let converter = try PCM16AudioConverter(inputSampleRate: format.sampleRate,
                                                channelCount: Int(format.channelCount))
        let current = AudioCaptureSession(token: token, engine: engine, input: input,
                                           ring: ring, converter: converter,
                                           channels: Int(format.channelCount),
                                           onFailure: onFailure, onLevel: onLevel, onLimit: onLimit)
        session = current
        do {
            try observeChanges(current, device: device)
            // Realtime callback: no Task/Dispatch work, Swift collection creation,
            // conversion, locks, I/O or retained framework buffers. The C writer
            // validates the Float32 ABL and copies it into preallocated storage.
            input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [ring] buffer, _ in
                _ = wisper_audio_ring_write(ring.pointer, buffer.audioBufferList, buffer.frameLength)
            }
            current.tapInstalled = true
            engine.prepare()
            try engine.start()
            guard try defaultInputDevice() == device else {
                throw WisperError.message("The microphone changed while recording was starting.")
            }
            if let failure = ringFailure(ring) { throw WisperError.message(failure) }
            current.startedAt = DispatchTime.now().uptimeNanoseconds
            current.lastFramesAt = current.startedAt
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.consume(token: token) }
            current.timer = timer
            timer.resume()
        } catch {
            current.cancelled = true
            stopHardware(current)
            // engine.stop/removeTap have stopped hardware; a ring writer, if
            // still finishing its bounded copy, keeps its own handle alive.
            // Serialize quiescence before allowing another start.
            completeWhenIdle(token: token)
            throw error
        }
    }

    private func consume(token: AudioCaptureToken) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let current = session, current.token == token, !current.stopping else { return }
        do {
            if wisper_audio_ring_error(current.ring.pointer) == WisperAudioRingErrorDurationLimit {
                current.limitReached = true
                stopHardware(current)
                completeWhenIdle(token: token)
                return
            }
            if let failure = ringFailure(current.ring) { throw WisperError.message(failure) }
            let frames = try drain(current)
            let now = DispatchTime.now().uptimeNanoseconds
            if frames > 0 { current.lastFramesAt = now }
            guard current.engine.isRunning else { throw WisperError.message("Microphone recording was interrupted. Start a new recording.") }
            guard now - current.lastFramesAt < 3_000_000_000 else {
                throw WisperError.message("The microphone stopped supplying audio. Start a new recording.")
            }
            if now - current.startedAt >= 300_000_000_000 {
                current.limitReached = true
                stopHardware(current)
                completeWhenIdle(token: token)
                return
            }
            if now - current.lastLevelAt >= 100_000_000 {
                current.lastLevelAt = now
                guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                    throw WisperError.message("Microphone access was revoked during recording.")
                }
                let onLevel = current.onLevel
                let level = current.converter.lastLevel
                Task { @MainActor in onLevel(level) }
            }
        } catch {
            current.failure = error.localizedDescription
            stopHardware(current)
            completeWhenIdle(token: token)
        }
    }

    @discardableResult
    private func drain(_ current: AudioCaptureSession) throws -> Int {
        var total = 0
        // At most the entire ring per tick; producer progress cannot monopolize
        // the serial queue and indefinitely postpone a queued Stop/Cancel.
        for _ in 0..<16 {
            let frames = wisper_audio_ring_read(current.ring.pointer, current.scratch,
                                                 UInt32(PCM16AudioConverter.blockFrames))
            if frames == 0 { break }
            try current.converter.append(interleaved: UnsafeBufferPointer(start: current.scratch,
                                                                           count: Int(frames) * current.channels),
                                         frameCount: Int(frames))
            total += Int(frames)
        }
        if let failure = ringFailure(current.ring) { throw WisperError.message(failure) }
        return total
    }

    private func stopHardware(_ current: AudioCaptureSession) {
        guard !current.stopping else { return }
        current.stopping = true
        wisper_audio_ring_close(current.ring.pointer)
        current.timer?.cancel()
        current.timer = nil
        for (center, observer) in current.notifications { center.removeObserver(observer) }
        current.notifications.removeAll()
        for observation in current.properties {
            var address = observation.address
            AudioObjectRemovePropertyListenerBlock(observation.object, &address, queue, observation.block)
        }
        current.properties.removeAll()
        current.engine.stop()
        if current.tapInstalled {
            current.input.removeTap(onBus: 0)
            current.tapInstalled = false
        }
    }

    private func completeWhenIdle(token: AudioCaptureToken) {
        guard let current = session, current.token == token else { return }
        guard wisper_audio_ring_producer_idle(current.ring.pointer) else {
            // Never busy-wait or block a realtime writer. The closed gate stops
            // new writers; final drain waits for the one accepted copy to finish.
            queue.asyncAfter(deadline: .now() + .milliseconds(2)) { self.completeWhenIdle(token: token) }
            return
        }
        let result: Result<RecordedAudio, Error>
        if current.cancelled {
            result = .failure(CancellationError())
        } else {
            do {
                if let message = current.failure ?? ringFailure(current.ring) {
                    throw WisperError.message(message)
                }
                try drain(current)
                result = .success(try current.converter.finish())
            } catch { result = .failure(error) }
        }
        session = nil
        lastCompletion = current.cancelled ? nil : (token, result)
        for completion in current.stops { completion.resume(with: result) }
        for completion in current.cancellations { completion.resume() }
        if case .success = result, current.limitReached {
            let onLimit = current.onLimit
            Task { @MainActor in onLimit() }
        }
        if case .failure(let error) = result, !current.cancelled {
            let onFailure = current.onFailure
            let message = error.localizedDescription
            Task { @MainActor in onFailure(message) }
        }
    }

    private func observeChanges(_ current: AudioCaptureSession, device: AudioDeviceID) throws {
        let ring = current.ring
        let center = NotificationCenter.default
        let configuration = center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                object: current.engine, queue: nil) { _ in
            // AVAudioEngine forbids teardown on its notification thread. Only
            // atomically close here; the capture queue performs the teardown.
            wisper_audio_ring_abort(ring.pointer, WisperAudioRingErrorDeviceChanged)
        }
        current.notifications.append((center, configuration))
        let sleep = workspaceNotifications.addObserver(forName: NSWorkspace.willSleepNotification,
                                                         object: nil, queue: nil) { _ in
            wisper_audio_ring_abort(ring.pointer, WisperAudioRingErrorInterrupted)
        }
        current.notifications.append((workspaceNotifications, sleep))
        let properties: [(AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal),
            (device, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
            (device, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (device, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        ]
        for (object, selector, scope) in properties {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                       mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { _, _ in
                wisper_audio_ring_abort(ring.pointer, WisperAudioRingErrorDeviceChanged)
            }
            let status = AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
            guard status == noErr else { throw WisperError.message("Unable to monitor microphone device changes (\(status)).") }
            current.properties.append(AudioPropertyObservation(object: object, address: address, block: block))
        }
    }

    private func defaultInputDevice() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else {
            throw WisperError.message("No microphone is available.")
        }
        return device
    }

    private func ringFailure(_ ring: AudioRingHandle) -> String? {
        switch wisper_audio_ring_error(ring.pointer) {
        case WisperAudioRingErrorNone: nil
        case WisperAudioRingErrorOverflow: "The microphone buffer overflowed. No partial recording was accepted. Try recording again."
        case WisperAudioRingErrorDurationLimit: nil // Finalize accepted frames as a visible automatic stop.
        case WisperAudioRingErrorInvalidBuffer: "The microphone audio format changed or supplied an incomplete buffer."
        case WisperAudioRingErrorConcurrentProducer: "The microphone supplied overlapping audio callbacks."
        case WisperAudioRingErrorDeviceChanged: "The microphone device or format changed. Start a new recording."
        case WisperAudioRingErrorInterrupted: "Microphone recording was interrupted. Start a new recording."
        default: "Microphone capture failed. Start a new recording."
        }
    }
}

// These containers never leave AudioCaptureWorker.queue and need no Sendable
// conformance. Closures installed on framework threads capture only ring handles.
private struct AudioPropertyObservation {
    let object: AudioObjectID
    let address: AudioObjectPropertyAddress
    let block: AudioObjectPropertyListenerBlock
}

private final class AudioCaptureSession {
    let token: AudioCaptureToken
    let engine: AVAudioEngine
    let input: AVAudioInputNode
    let ring: AudioRingHandle
    let converter: PCM16AudioConverter
    let channels: Int
    let scratch: UnsafeMutablePointer<Float>
    let onFailure: @MainActor @Sendable (String) -> Void
    let onLevel: @MainActor @Sendable (Float) -> Void
    let onLimit: @MainActor @Sendable () -> Void
    var timer: DispatchSourceTimer?
    var notifications: [(NotificationCenter, NSObjectProtocol)] = []
    var properties: [AudioPropertyObservation] = []
    var tapInstalled = false
    var stopping = false
    var cancelled = false
    var limitReached = false
    var failure: String?
    var startedAt: UInt64 = 0
    var lastFramesAt: UInt64 = 0
    var lastLevelAt: UInt64 = 0
    var stops: [CheckedContinuation<RecordedAudio, Error>] = []
    var cancellations: [CheckedContinuation<Void, Never>] = []

    init(token: AudioCaptureToken, engine: AVAudioEngine, input: AVAudioInputNode,
         ring: AudioRingHandle, converter: PCM16AudioConverter, channels: Int,
         onFailure: @escaping @MainActor @Sendable (String) -> Void,
         onLevel: @escaping @MainActor @Sendable (Float) -> Void,
         onLimit: @escaping @MainActor @Sendable () -> Void) {
        self.token = token
        self.engine = engine
        self.input = input
        self.ring = ring
        self.converter = converter
        self.channels = channels
        self.onFailure = onFailure
        self.onLevel = onLevel
        self.onLimit = onLimit
        scratch = .allocate(capacity: PCM16AudioConverter.blockFrames * channels)
    }

    deinit { scratch.deallocate() }
}
