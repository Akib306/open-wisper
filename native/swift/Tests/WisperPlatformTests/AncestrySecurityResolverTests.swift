import Testing
@testable import WisperPlatform

@Suite("Secure field ancestry") @MainActor
struct AncestrySecurityResolverTests {
    @Test func deeplyNestedWebComposerCanReachItsWindow() {
        let secure = AncestrySecurityResolver.isSecure(from: 0, same: ==) { depth in
            .init(role: depth == 48 ? "AXWindow" : "AXGroup", secure: false,
                parent: depth == 48 ? nil : depth + 1)
        }
        #expect(secure == false)
    }

    @Test func secureAncestorIsNeverSkippedInADeepEditor() {
        let secure = AncestrySecurityResolver.isSecure(from: 0, same: ==) { depth in
            .init(role: depth == 48 ? "AXWindow" : "AXGroup", secure: depth == 35,
                parent: depth == 48 ? nil : depth + 1)
        }
        #expect(secure == true)
    }

    @Test func missingParentCycleAndUnboundedTreeCannotAuthorizeInsertion() {
        #expect(AncestrySecurityResolver.isSecure(from: 0, same: ==) { _ in
            .init(role: "AXGroup", secure: false, parent: nil)
        } == nil)
        #expect(AncestrySecurityResolver.isSecure(from: 0, same: ==) { node in
            .init(role: "AXGroup", secure: false, parent: node)
        } == nil)
        #expect(AncestrySecurityResolver.isSecure(from: 0, same: ==) { depth in
            .init(role: "AXGroup", secure: false, parent: depth + 1)
        } == nil)
    }
}
