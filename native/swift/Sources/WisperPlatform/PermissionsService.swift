import AppKit
@preconcurrency import ApplicationServices
import AVFoundation
import WisperCore

@MainActor public final class PermissionsService: Permissions {
    private let microphoneAuthorization: () -> AVAuthorizationStatus
    private let requestMicrophoneAccess: (@escaping @Sendable (Bool) -> Void) -> Void

    public convenience init() {
        self.init(microphoneAuthorization: { AVCaptureDevice.authorizationStatus(for: .audio) },
                  requestMicrophoneAccess: { AVCaptureDevice.requestAccess(for: .audio, completionHandler: $0) })
    }

    init(microphoneAuthorization: @escaping () -> AVAuthorizationStatus,
         requestMicrophoneAccess: @escaping (@escaping @Sendable (Bool) -> Void) -> Void) {
        self.microphoneAuthorization = microphoneAuthorization
        self.requestMicrophoneAccess = requestMicrophoneAccess
    }

    public var microphoneGranted: Bool { microphoneAuthorization() == .authorized }
    public var accessibilityGranted: Bool { AXIsProcessTrusted() }
    public var microphoneStatus: String {
        switch microphoneAuthorization() {
        case .authorized: "Allowed"
        case .notDetermined: "Requested when you record"
        case .denied: "Denied — enable in System Settings"
        case .restricted: "Restricted by this Mac"
        @unknown default: "Unavailable"
        }
    }

    public func requestMicrophoneIfNeeded() async throws {
        try Task.checkCancellation()
        switch microphoneAuthorization() {
        case .authorized: return
        case .notDetermined:
            let request = MicrophonePermissionRequest()
            let granted = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    guard request.install(continuation) else { return }
                    guard !Task.isCancelled else {
                        request.finish(.failure(CancellationError()))
                        return
                    }
                    requestMicrophoneAccess { granted in request.finish(.success(granted)) }
                }
            } onCancel: {
                // macOS owns the dialog; cancellation releases our waiter without
                // waiting for a response or authorizing capture on a late response.
                request.finish(.failure(CancellationError()))
            }
            try Task.checkCancellation()
            guard granted else { throw WisperError.message("Microphone access is off. Enable Open Wisper in System Settings → Privacy & Security → Microphone, then record again.") }
        default:
            throw WisperError.message("Microphone access is off. Enable Open Wisper in System Settings → Privacy & Security → Microphone, then record again.")
        }
    }

    public func openMicrophoneSettings() { openPrivacyPane("Privacy_Microphone") }
    // Only invoked by an explicit button; no launch-time prompt loops.
    public func openAccessibilitySettings() {
        if !accessibilityGranted {
            // Register this packaged app in TCC only after its explicit setup button.
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        openPrivacyPane("Privacy_Accessibility")
    }
    private func openPrivacyPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// The OS callback and task cancellation can arrive on different threads and in
/// either order, including before the continuation is installed.
private final class MicrophonePermissionRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Bool, any Error>?
    private var continuation: CheckedContinuation<Bool, any Error>?

    func install(_ continuation: CheckedContinuation<Bool, any Error>) -> Bool {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func finish(_ result: Result<Bool, any Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
