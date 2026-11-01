import Foundation

/// Bounded metadata traversal: deeply nested web editors can exceed 24 parents.
/// Only a window/application root establishes nonsecure ancestry. Missing data,
/// cycles, excessive depth and timeout remain unknown and cannot authorize text.
@MainActor enum AncestrySecurityResolver {
    struct Node<Element> {
        let role: String
        let secure: Bool
        let parent: Element?
    }

    static func isSecure<Element>(from start: Element,
        same: (Element, Element) -> Bool,
        observe: (Element) -> Node<Element>?) -> Bool? {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
        var current = start
        for _ in 0..<128 {
            guard ContinuousClock.now < deadline, let node = observe(current), ContinuousClock.now < deadline else { return nil }
            if node.secure { return true }
            if node.role == "AXApplication" || node.role == "AXWindow" { return false }
            guard let parent = node.parent, !same(current, parent) else { return nil }
            current = parent
        }
        return nil
    }
}
