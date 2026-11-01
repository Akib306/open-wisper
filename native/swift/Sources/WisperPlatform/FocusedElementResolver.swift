import ApplicationServices

/// Resolve macOS's global focus first. Some editors return a document/container
/// for app-local focus even while the system-wide focus points to its text input.
/// A candidate from another process must never become a dictation destination.
@MainActor enum FocusedElementResolver {
    struct Candidate {
        let element: AXUIElement
        let processID: Int32?
        let role: String?
    }

    static func resolve(systemWide: Candidate?, application: Candidate?, processID: Int32) -> Candidate? {
        // Conflicting global focus means the frontmost-app observation is stale.
        if let systemWide, systemWide.processID != processID { return nil }
        for candidate in [systemWide, application].compactMap({ $0 }) {
            guard candidate.processID == processID,
                  let role = candidate.role, [kAXTextFieldRole, kAXTextAreaRole].contains(role) else { continue }
            return candidate
        }
        return nil
    }
}
