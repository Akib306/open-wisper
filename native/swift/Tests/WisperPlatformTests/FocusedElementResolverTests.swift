import ApplicationServices
import Foundation
import Testing
@testable import WisperPlatform

@Suite("Focused editor resolution") @MainActor
struct FocusedElementResolverTests {
    @Test func followsFocusedContainerToItsTextInput() throws {
        let container = AXUIElementCreateApplication(234_567)
        let field = AXUIElementCreateApplication(234_568)
        let resolved = try #require(FocusedElementResolver.resolve(
            systemWide: .init(element: container, processID: 123, role: "AXWebArea"),
            application: nil, processID: 123, focusedChild: { candidate in
                CFEqual(candidate.element, container) ? .init(element: field, processID: 123, role: "AXTextArea") : nil
            }))
        #expect(CFEqual(resolved.element, field))
    }

    @Test func nestedFocusRejectsForeignProcessesAndCycles() {
        let container = AXUIElementCreateApplication(234_567)
        let field = AXUIElementCreateApplication(234_568)
        let root = FocusedElementResolver.Candidate(element: container, processID: 123, role: "AXWebArea")
        let fallback = FocusedElementResolver.Candidate(element: field, processID: 123, role: "AXTextArea")
        #expect(FocusedElementResolver.resolve(systemWide: root, application: fallback, processID: 123,
            focusedChild: { _ in .init(element: field, processID: 999, role: "AXTextArea") }) == nil)
        #expect(FocusedElementResolver.resolve(systemWide: root, application: fallback, processID: 123,
            focusedChild: { _ in root }) == nil)
    }

    @Test func nestedFocusStopsAtTheDepthLimit() {
        var reads = 0
        let root = FocusedElementResolver.Candidate(element: AXUIElementCreateApplication(234_567),
            processID: 123, role: "AXGroup")
        #expect(FocusedElementResolver.resolve(systemWide: root, application: nil, processID: 123,
            focusedChild: { _ in
                reads += 1
                return .init(element: AXUIElementCreateApplication(Int32(234_567 + reads)),
                    processID: 123, role: "AXGroup")
            }) == nil)
        #expect(reads == 15)
    }

    @Test func slowFocusedChildCannotAuthorizeInsertionAfterTheDeadline() {
        let root = FocusedElementResolver.Candidate(element: AXUIElementCreateApplication(234_567),
            processID: 123, role: "AXGroup")
        #expect(FocusedElementResolver.resolve(systemWide: root, application: nil, processID: 123,
            focusedChild: { _ in
                Thread.sleep(forTimeInterval: 0.3)
                return .init(element: AXUIElementCreateApplication(234_568), processID: 123, role: "AXTextArea")
            }) == nil)
    }

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
