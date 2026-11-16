import CoreGraphics
import Foundation

public struct IndicatorLayout: Equatable, Sendable {
    public let frame: CGRect
    public let cameraWidth: CGFloat
    public let cameraHeight: CGFloat

    public init(screen: CGRect, visibleFrame: CGRect, cameraWidth: CGFloat = 0, cameraHeight: CGFloat = 0,
                phase: SessionPhase = .recording, feedback: IndicatorFeedback = .active) {
        self.cameraWidth = 0
        self.cameraHeight = 0
        let preferredWidth: CGFloat
        if feedback == .inserted || feedback == .copied || feedback == .cancelled { preferredWidth = 234 }
        else if feedback == .insertionRequested { preferredWidth = 280 }
        else if phase.isActive && phase != .recording { preferredWidth = 218 }
        else { preferredWidth = 248 }
        let width = max(0, min(preferredWidth, visibleFrame.width))
        let height = min(44, max(0, visibleFrame.height))
        let bottomInset = min(28, max(0, visibleFrame.height - height))
        frame = CGRect(x: visibleFrame.midX - width / 2,
            y: visibleFrame.minY + bottomInset, width: width, height: height)
    }
}

public enum IndicatorFeedback: Equatable, Sendable {
    case hidden, active, review, copied, inserted, insertionRequested, cancelled

    public init(phase: SessionPhase, needsReview: Bool, outcome: DeliveryOutcome?) {
        if phase.isActive { self = .active }
        else if outcome == .copied { self = .copied }
        else if needsReview { self = .review }
        else if phase == .cancelled || outcome == .cancelled { self = .cancelled }
        else if outcome == .insertionVerified { self = .inserted }
        else if outcome == .insertionRequested { self = .insertionRequested }
        else { self = .hidden }
    }
}
