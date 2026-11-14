import CoreGraphics
import Foundation
import Testing
@testable import WisperCore

@Suite("Bottom indicator")
struct IndicatorPresentationTests {
    @Test func notchedDisplayUsesVisibleBottom() {
        let layout = IndicatorLayout(screen: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 50, width: 1512, height: 900), cameraWidth: 180, cameraHeight: 32)
        #expect(layout.frame.minY == 78)
        #expect(layout.cameraWidth == 0)
        #expect(layout.cameraHeight == 0)
        #expect(layout.frame.height == 44)
        #expect(layout.frame.midX == 756)
    }

    @Test func shiftedExternalDisplayUsesVisibleBottom() {
        let layout = IndicatorLayout(screen: CGRect(x: -1920, y: 100, width: 1920, height: 1080),
            visibleFrame: CGRect(x: -1920, y: 150, width: 1920, height: 1000))
        #expect(layout.frame.minY == 178)
        #expect(layout.frame.width == 248)
        #expect(layout.frame.midX == -960)
        #expect(layout.cameraHeight == 0)
    }

    @Test func terminalFeedbackNeverOverridesRecovery() {
        #expect(IndicatorFeedback(phase: .idle, needsReview: false, outcome: nil) == .hidden)
        #expect(IndicatorFeedback(phase: .recording, needsReview: false, outcome: nil) == .active)
        #expect(IndicatorFeedback(phase: .idle, needsReview: true, outcome: .blocked) == .review)
        #expect(IndicatorFeedback(phase: .idle, needsReview: false, outcome: .insertionVerified) == .inserted)
        #expect(IndicatorFeedback(phase: .idle, needsReview: false, outcome: .insertionRequested) == .insertionRequested)
        #expect(IndicatorFeedback(phase: .cancelled, needsReview: false, outcome: nil) == .cancelled)
    }

    @Test func acknowledgedCopyHidesPillAndCancellationSurvivesIdle() {
        #expect(IndicatorFeedback(phase: .idle, needsReview: true, outcome: .copied) == .hidden)
        #expect(IndicatorFeedback(phase: .idle, needsReview: false, outcome: .cancelled) == .cancelled)
        #expect(IndicatorFeedback(phase: .idle, needsReview: true, outcome: .failed) == .review)
    }

    @Test func narrowNotchedDisplayUsesVisibleBottom() {
        let layout = IndicatorLayout(screen: CGRect(x: 0, y: 0, width: 300, height: 900),
            visibleFrame: CGRect(x: 0, y: 40, width: 300, height: 828), cameraWidth: 260, cameraHeight: 32)
        #expect(layout.cameraHeight == 0)
        #expect(layout.frame.minY == 68)
        #expect(layout.frame.width == 248)
    }

    @Test func processingAndCompletionUseCompactWidths() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let visible = CGRect(x: 0, y: 0, width: 1920, height: 1055)
        let processing = IndicatorLayout(screen: screen, visibleFrame: visible, phase: .transcribing)
        let completed = IndicatorLayout(screen: screen, visibleFrame: visible, feedback: .inserted)
        #expect(processing.frame.width == 218)
        #expect(completed.frame.width == 234)
    }

    @Test func narrowDisplayDoesNotClipRecoveryActions() {
        let screen = CGRect(x: 100, y: 0, width: 240, height: 800)
        let visible = CGRect(x: 120, y: 0, width: 220, height: 775)
        let layout = IndicatorLayout(screen: screen, visibleFrame: visible)
        #expect(layout.frame.minX >= visible.minX)
        #expect(layout.frame.maxX <= visible.maxX)
    }

    @Test func cameraDoesNotChangeCapsuleSize() {
        let layout = IndicatorLayout(screen: CGRect(x: 0, y: 0, width: 1800, height: 1169),
            visibleFrame: CGRect(x: 0, y: 0, width: 1800, height: 1130), cameraWidth: 220, cameraHeight: 38)
        #expect(layout.frame.width == 248)
        #expect(layout.frame.minY == 28)
        #expect(layout.frame.height - layout.cameraHeight == 44)
    }
}
