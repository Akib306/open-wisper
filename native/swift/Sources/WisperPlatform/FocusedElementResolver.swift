import ApplicationServices
import Foundation

/// Resolve macOS's global focus first. Some editors return a document/container
/// for app-local focus even while the system-wide focus points to its text input.
/// A candidate from another process must never become a dictation destination.
@MainActor enum FocusedElementResolver {
    struct Candidate {
        let element: AXUIElement
        let processID: Int32?
        let role: String?
    }

    static func resolve(systemWide: Candidate?, application: Candidate?, processID: Int32,
                        focusedChild: (Candidate) -> Candidate? = { _ in nil }) -> Candidate? {
        // Conflicting global focus means the frontmost-app observation is stale.
        if let systemWide, systemWide.processID != processID { return nil }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
        for root in [systemWide, application].compactMap({ $0 }) {
            var candidate = root
            var visited: [AXUIElement] = []
            for _ in 0..<16 {
                guard ContinuousClock.now < deadline, candidate.processID == processID,
                      !visited.contains(where: { CFEqual($0, candidate.element) }) else { return nil }
                visited.append(candidate.element)
                if let role = candidate.role, [kAXTextFieldRole, kAXTextAreaRole].contains(role) {
                    return candidate
                }
                if visited.count == 16 { return nil }
                guard let child = focusedChild(candidate) else { break }
                candidate = child
            }
        }
        return nil
    }
}
