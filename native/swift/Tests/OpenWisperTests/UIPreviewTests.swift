import Foundation
import Testing
import WisperCore
@testable import OpenWisper

@Suite("Permission-free UI fixtures") @MainActor
struct UIPreviewTests {
    @Test(arguments: ["idle", "recording", "processing", "review", "failure", "cancelled"])
    func fixturesReachTheirDeclaredState(state: String) async throws {
        let session = try await UIPreview.session(state: state)
        switch state {
        case "idle": #expect(session.phase == .idle && !session.needsReview)
        case "recording": #expect(session.phase == .recording && session.recordingStartedAt != nil)
        case "processing": #expect(session.phase == .transcribing)
        case "review": #expect(session.needsReview && !session.transcript.isEmpty)
        case "failure": #expect(session.needsReview && session.failure != nil)
        case "cancelled": #expect(!session.phase.isActive && session.transcript.isEmpty)
        default: Issue.record("Unexpected preview state")
        }
        await session.shutdown()
    }

    @Test func previewSettingsStayInMemoryAndUseNoHotkey() {
        let model = AppModel(preview: true)
        #expect(model.hotkeys == nil)
        #expect(model.engineReady)
        #expect(!model.settings.automaticInsertion)
        var settings = model.settings
        settings.maximumDuration = 60
        model.save(settings)
        #expect(model.settings.maximumDuration == 60)
    }

    @Test func clearingProfileWhileVerificationIsRunningStopsChecking() {
        let model = AppModel(preview: true)
        model.settings.engineProfilePath = "/fixture/missing-profile.json"
        model.verifyEngine()
        #expect(model.checkingEngine)
        model.settings.engineProfilePath = ""
        model.verifyEngine()
        #expect(!model.checkingEngine)
        #expect(!model.engineReady)
        #expect(model.engineDescription == "Choose a local engine profile to get started.")
    }

    @Test func invalidFixtureIsRejected() async {
        await #expect(throws: WisperError.self) { try await UIPreview.session(state: "unknown") }
    }
}
