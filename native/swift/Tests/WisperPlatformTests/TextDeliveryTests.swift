import AppKit
import ApplicationServices
import Testing
import WisperCore
@testable import WisperPlatform

@MainActor final class FakeInsertionSystem: TextInsertionSystem {
    var accessibilityGranted = true
    var focusFailureReason: String?
    var focusMetadata: [String: String] = [:]
    var preparations = 0
    func prepareForDictation() { preparations += 1 }
    var selectedTextResult = AXError.success
    var writes = 0
    var pastes = 0
    var pasteAvailable = true
    var current: FocusedTextTarget?
    var onPaste: (() -> Void)?

    init(selectedText: Bool, webContent: Bool = false) {
        current = FocusedTextTarget(element: AXUIElementCreateApplication(987_654),
            context: InsertionContext(processID: 987_654, processStartedAt: Date(timeIntervalSince1970: 10),
                bundleID: "test.scratch-editor", role: "AXTextArea", selectionLocation: 4,
                selectionLength: 0, editable: true, secure: false), supportsSelectedText: selectedText,
            isWebContent: webContent)
    }
    func focusedTarget() -> FocusedTextTarget? { current }
    func replaceSelection(_ text: String, in target: FocusedTextTarget) -> AXError {
        writes += 1
        return selectedTextResult
    }
    func preparePaste(to processID: Int32) -> (() -> Void)? {
        #expect(processID == 987_654)
        guard pasteAvailable else { return nil }
        return { self.pastes += 1; self.onPaste?() }
    }
}

@Suite("Cursor delivery and clipboard ownership") @MainActor
struct TextDeliveryTests {
    @Test func preparationEnablesEditorSupportWithoutCapturingTheDestination() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let system = FakeInsertionSystem(selectedText: true)
        let delivery = AccessibilityDelivery(system: system, paster: ClipboardPaster(pasteboard: board, settle: {}))
        delivery.prepareForDictation()
        #expect(system.preparations == 1)
        #expect(await delivery.deliver("fixture", to: nil).outcome == .blocked)
        #expect(system.writes == 0 && system.pastes == 0)
    }

    @Test func readinessDoesNotDiscardTheSavedStopTarget() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let system = FakeInsertionSystem(selectedText: true)
        let delivery = AccessibilityDelivery(system: system, paster: ClipboardPaster(pasteboard: board, settle: {}))
        let token = delivery.snapshot()
        #expect(delivery.readiness().eligible)
        #expect(await delivery.deliver("fixture", to: token).outcome == .insertionRequested)
        #expect(system.writes == 1)
    }

    @Test func unavailableSelectionPreservesItsSpecificReason() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let system = FakeInsertionSystem(selectedText: true)
        system.current = nil
        system.focusFailureReason = "The editor did not expose its cursor selection to Accessibility."
        let delivery = AccessibilityDelivery(system: system, paster: ClipboardPaster(pasteboard: board, settle: {}))
        let token = delivery.snapshot()
        let result = await delivery.deliver("fixture", to: token)
        #expect(result.outcome == .blocked && result.message == system.focusFailureReason)
        #expect(system.writes == 0 && system.pastes == 0)
    }

    @Test func directReplacementDoesNotUseClipboardAndConsumesTokenOnce() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let originalCount = board.changeCount
        let system = FakeInsertionSystem(selectedText: true)
        let delivery = AccessibilityDelivery(system: system, paster: ClipboardPaster(pasteboard: board, settle: {}))
        let token = delivery.snapshot()
        #expect(await delivery.deliver("spoken words", to: token).outcome == .insertionRequested)
        #expect(await delivery.deliver("spoken words", to: token).outcome == .blocked)
        #expect(system.writes == 1 && system.pastes == 0)
        #expect(board.changeCount == originalCount)
    }

    @Test(arguments: [false, true])
    func unsupportedSelectionUsesOnePaste(selectedText: Bool) async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let system = FakeInsertionSystem(selectedText: selectedText)
        system.selectedTextResult = .attributeUnsupported
        system.onPaste = { #expect(board.string(forType: .string) == "spoken words") }
        let delivery = AccessibilityDelivery(system: system, paster: ClipboardPaster(pasteboard: board, settle: {}))
        let token = delivery.snapshot()
        #expect(await delivery.deliver("spoken words", to: token).outcome == .insertionRequested)
        #expect(system.pastes == 1 && system.writes == (selectedText ? 1 : 0))
        #expect(board.string(forType: .string) == "original")
    }

    @Test func ambiguousAXResultNeverRetriesWithPaste() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let system = FakeInsertionSystem(selectedText: true)
        system.selectedTextResult = .cannotComplete
        let delivery = AccessibilityDelivery(system: system, paster: ClipboardPaster(pasteboard: board, settle: {}))
        let token = delivery.snapshot()
        #expect(await delivery.deliver("spoken words", to: token).outcome == .insertionRequested)
        #expect(system.writes == 1 && system.pastes == 0)
    }

    @Test(arguments: [false, true])
    func webEditorUsesPasteWithoutAnUnverifiedAXWrite(pasteAvailable: Bool) async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let system = FakeInsertionSystem(selectedText: true, webContent: true)
        system.pasteAvailable = pasteAvailable
        system.onPaste = { #expect(board.string(forType: .string) == "spoken words") }
        let delivery = AccessibilityDelivery(system: system, paster: ClipboardPaster(pasteboard: board, settle: {}))
        let token = delivery.snapshot()
        let result = await delivery.deliver("spoken words", to: token)
        #expect(result.outcome == (pasteAvailable ? .insertionRequested : .blocked))
        #expect(system.writes == 0 && system.pastes == (pasteAvailable ? 1 : 0))
        #expect(await delivery.deliver("spoken words", to: token).outcome == .blocked)
        #expect(board.string(forType: .string) == "original")
    }

    @Test func changedSelectionOrRevokedAccessCannotWrite() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let system = FakeInsertionSystem(selectedText: false)
        let delivery = AccessibilityDelivery(system: system, paster: ClipboardPaster(pasteboard: board, settle: {}))
        let token = delivery.snapshot()
        let field = try #require(system.current)
        var changed = field.context
        changed.selectionLocation += 1
        system.current = FocusedTextTarget(element: field.element, context: changed, supportsSelectedText: false)
        #expect(await delivery.deliver("spoken words", to: token).outcome == .blocked)
        let next = delivery.snapshot()
        system.accessibilityGranted = false
        let result = await delivery.deliver("spoken words", to: next)
        #expect(result.outcome == .blocked && result.message.contains("Accessibility"))
        #expect(system.writes == 0 && system.pastes == 0)
    }

    @Test func pasteReplacesNativeTextSelectionAndRestoresRichClipboard() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let original = NSPasteboardItem()
        original.setString("original", forType: .string)
        original.setString("<b>original</b>", forType: .html)
        board.writeObjects([original])
        // An in-process, disposable TextKit fixture consumes the private board.
        // This does not post OS events or touch the user's editor or clipboard.
        let editor = NSTextView()
        editor.string = "Before selected after"
        editor.setSelectedRange(NSRange(location: 7, length: 8))
        let paster = ClipboardPaster(pasteboard: board, settle: {})
        let result = await paster.paste("spoken", revalidate: { true }, send: {
            #expect(editor.readSelection(from: board))
        })
        #expect(result.outcome == .insertionRequested)
        #expect(editor.string == "Before spoken after")
        #expect(board.string(forType: .string) == "original")
        #expect(board.string(forType: .html) == "<b>original</b>")
        #expect(board.string(forType: ClipboardPaster.markerType) == nil)
    }

    @Test func aNewCopyDuringPasteIsNeverOverwritten() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("old clipboard", forType: .string)
        let paster = ClipboardPaster(pasteboard: board, settle: {
            board.clearContents()
            board.setString("new user copy", forType: .string)
        })
        var sent = 0
        let result = await paster.paste("spoken", revalidate: { true }, send: {
            sent += 1
            #expect(board.string(forType: .string) == "spoken")
        })
        #expect(result.outcome == .insertionRequested)
        #expect(sent == 1 && board.string(forType: .string) == "new user copy")
    }

    @Test func delayedConsumerReceivesTranscriptBeforeClipboardRestoration() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let consumer = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(650))
            return board.string(forType: .string)
        }
        let paster = ClipboardPaster(pasteboard: board)
        let result = await paster.paste("spoken", revalidate: { true }, send: {})
        #expect(try await consumer.value == "spoken")
        #expect(result.outcome == .insertionRequested)
        #expect(board.string(forType: .string) == "original")
    }

    @Test func markerReadsDoNotAcknowledgeTranscriptConsumption() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        var settlements = 0
        let paster = ClipboardPaster(pasteboard: board, requestTimeout: .milliseconds(40), settle: { settlements += 1 })
        let result = await paster.paste("spoken", revalidate: { true }, send: {
            #expect(board.string(forType: ClipboardPaster.markerType) != nil)
        })
        #expect(result.outcome == .insertionRequested && result.message.contains("no clipboard read was observed"))
        #expect(settlements == 0)
        #expect(board.string(forType: .string) == "original")
    }

    @Test func newCopyWhileAwaitingConsumptionIsPreserved() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let paster = ClipboardPaster(pasteboard: board, requestTimeout: .milliseconds(200), settle: {})
        let result = await paster.paste("spoken", revalidate: { true }, send: {
            Task { @MainActor in
                board.clearContents()
                board.setString("new user copy", forType: .string)
            }
        })
        #expect(result.outcome == .insertionRequested)
        #expect(board.string(forType: .string) == "new user copy")
    }

    @Test func cancellationWhileAwaitingConsumptionRestoresWithoutRetrying() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        var sent = 0
        let paster = ClipboardPaster(pasteboard: board, settle: {})
        let task = Task { await paster.paste("spoken", revalidate: { true }, send: { sent += 1 }) }
        while sent == 0 { await Task.yield() }
        task.cancel()
        _ = await task.value
        #expect(sent == 1 && board.string(forType: .string) == "original")
    }

    @Test func destinationChangeAfterClipboardPreparationRestoresWithoutPasting() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        var checks = 0, sent = 0
        let paster = ClipboardPaster(pasteboard: board, settle: {})
        let result = await paster.paste("spoken", revalidate: { checks += 1; return checks < 3 }, send: { sent += 1 })
        #expect(result.outcome == .blocked && sent == 0)
        #expect(board.string(forType: .string) == "original")
    }

    @Test func oversizedAndPromisedClipboardsAreLeftUntouched() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("larger than the snapshot budget", forType: .string)
        var sent = 0
        let small = ClipboardPaster(pasteboard: board, maximumBytes: 4, settle: {})
        let count = board.changeCount
        #expect(await small.paste("spoken", revalidate: { true }, send: { sent += 1 }).outcome == .blocked)
        #expect(board.changeCount == count && sent == 0)
        board.clearContents()
        board.setString("promised fixture", forType: NSPasteboard.PasteboardType("test.file-promise"))
        let promisedCount = board.changeCount
        let paster = ClipboardPaster(pasteboard: board, settle: {})
        #expect(await paster.paste("spoken", revalidate: { true }, send: { sent += 1 }).outcome == .blocked)
        #expect(board.changeCount == promisedCount && sent == 0)
    }

    @Test func cancelledPasteNeverChangesClipboard() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let originalCount = board.changeCount
        var sent = 0
        let paster = ClipboardPaster(pasteboard: board, settle: {})
        let task = Task { await paster.paste("spoken", revalidate: { true }, send: { sent += 1 }) }
        task.cancel()
        _ = await task.value
        #expect(sent == 0 && board.changeCount == originalCount)
    }
}
