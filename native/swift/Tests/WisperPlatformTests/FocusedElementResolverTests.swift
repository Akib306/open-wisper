import ApplicationServices
import Testing
@testable import WisperPlatform

@Suite("Focused editor resolution") @MainActor
struct FocusedElementResolverTests {
    @Test func systemWideTextInputIsUsedWhenApplicationReportsItsDocument() throws {
        let field = AXUIElementCreateApplication(234_567)
        let document = AXUIElementCreateApplication(234_568)
        let resolved = try #require(FocusedElementResolver.resolve(
            systemWide: .init(element: field, processID: 123, role: "AXTextArea"),
            application: .init(element: document, processID: 123, role: "AXWebArea"), processID: 123))
        #expect(CFEqual(resolved.element, field))
    }

    @Test func conflictingGlobalFocusRejectsEvenAnAppLocalTextField() {
        let unrelated = AXUIElementCreateApplication(234_567)
        let field = AXUIElementCreateApplication(234_568)
        #expect(FocusedElementResolver.resolve(
            systemWide: .init(element: unrelated, processID: 999, role: "AXTextArea"),
            application: .init(element: field, processID: 123, role: "AXTextField"), processID: 123) == nil)
    }

    @Test func appLocalFocusIsUsedWhenGlobalFocusIsUnavailable() throws {
        let field = AXUIElementCreateApplication(234_568)
        let resolved = try #require(FocusedElementResolver.resolve(systemWide: nil,
            application: .init(element: field, processID: 123, role: "AXTextField"), processID: 123))
        #expect(CFEqual(resolved.element, field))
    }

    @Test func missingIdentityAndNonTextRolesRemainIneligible() {
        let field = AXUIElementCreateApplication(234_567)
        #expect(FocusedElementResolver.resolve(
            systemWide: .init(element: field, processID: nil, role: "AXTextArea"),
            application: .init(element: field, processID: 123, role: "AXWebArea"), processID: 123) == nil)
    }
}
