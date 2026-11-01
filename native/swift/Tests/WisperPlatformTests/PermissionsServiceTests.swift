import AVFoundation
import Foundation
import Testing
@testable import WisperPlatform

@Suite("Cancellable microphone permission") @MainActor
struct PermissionsServiceTests {
    @Test func authorizedAccessDoesNotPrompt() async throws {
        var requests = 0
        let service = PermissionsService(microphoneAuthorization: { .authorized },
                                         requestMicrophoneAccess: { _ in requests += 1 })
        try await service.requestMicrophoneIfNeeded()
        #expect(service.microphoneGranted)
        #expect(requests == 0)
    }

    @Test(arguments: [AVAuthorizationStatus.denied, .restricted])
    func deniedAccessDoesNotReprompt(status: AVAuthorizationStatus) async {
        var requests = 0
        let service = PermissionsService(microphoneAuthorization: { status },
                                         requestMicrophoneAccess: { _ in requests += 1 })
        for _ in 0..<2 {
            do {
                try await service.requestMicrophoneIfNeeded()
                Issue.record("Denied access should fail")
            } catch {
                #expect(!(error is CancellationError))
                #expect(error.localizedDescription.contains("System Settings"))
            }
        }
        #expect(!service.microphoneGranted)
        #expect(requests == 0)
    }

    @Test(arguments: [true, false])
    func permissionResponseIsRespected(granted: Bool) async {
        var requests = 0
        let service = PermissionsService(microphoneAuthorization: { .notDetermined },
            requestMicrophoneAccess: { response in requests += 1; response(granted) })
        do {
            try await service.requestMicrophoneIfNeeded()
            #expect(granted)
        } catch {
            #expect(!granted)
            #expect(error.localizedDescription.contains("System Settings"))
        }
        #expect(requests == 1)
    }

    @Test(arguments: [true, false])
    func cancellationDoesNotWaitForTheDialog(granted: Bool) async throws {
        var response: (@Sendable (Bool) -> Void)?
        var finished = false
        let service = PermissionsService(microphoneAuthorization: { .notDetermined },
                                         requestMicrophoneAccess: { response = $0 })
        let task = Task {
            defer { finished = true }
            try await service.requestMicrophoneIfNeeded()
        }
        try await waitUntil { response != nil }
        task.cancel()
        do {
            // Assert completion BEFORE simulating the user's response. A direct
            // await of the OS request would leave Cancel and Quit blocked here.
            try await waitUntil { finished }
        } catch {
            response?(granted) // Release a regressed implementation before failing.
            _ = await task.result
            throw error
        }
        switch await task.result {
        case .success: Issue.record("Cancellation must not grant recording access")
        case .failure(let error): #expect(error is CancellationError)
        }
        // A late callback must not resume the continuation a second time.
        await Task.detached { [response] in response?(granted) }.value
    }

    @Test func alreadyCancelledTaskDoesNotPrompt() async {
        var requests = 0
        let service = PermissionsService(microphoneAuthorization: { .notDetermined },
                                         requestMicrophoneAccess: { _ in requests += 1 })
        let task = Task { try await service.requestMicrophoneIfNeeded() }
        task.cancel()
        switch await task.result {
        case .success: Issue.record("An already cancelled task must fail")
        case .failure(let error): #expect(error is CancellationError)
        }
        #expect(requests == 0)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw PermissionTestTimeout() }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

private struct PermissionTestTimeout: Error {}
