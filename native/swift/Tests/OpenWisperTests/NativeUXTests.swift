import AppKit
import SwiftUI
import Testing
import WisperCore
@testable import OpenWisper

@Suite("Native keyboard journeys", .serialized) @MainActor
struct NativeUXTests {
    @Test func readyAndEmptyReviewAreConnected() throws {
        let model = AppModel(preview: true)
        let navigation = WindowNavigation()
        let window = makeWindow(model: model, navigation: navigation)
        defer { window.close() }
        try press("2", keyCode: 19, in: window)
        settleLayout(window)
        #expect(navigation.reviewSelected)
        try press("1", keyCode: 18, in: window)
        settleLayout(window)
        #expect(!navigation.reviewSelected)
    }

    @Test func unavailableEngineHasAnActionablePrimaryControl() throws {
        let model = AppModel(preview: true)
        try UIPreview.configureEngine(model, state: "missing")
        let window = makeWindow(model: model, navigation: WindowNavigation())
        defer { window.close() }
        try press("\r", keyCode: 36, in: window)
        settleLayout(window)
        #expect(model.settingsOpen)
    }

    @Test func longTranscriptCanBeCopiedFromTheKeyboard() async throws {
        let session = try await UIPreview.session(state: "long-review")
        let model = AppModel(preview: true, previewSession: session)
        let navigation = WindowNavigation()
        navigation.reviewSelected = true
        let window = makeWindow(model: model, navigation: navigation)
        defer { window.close() }
        try press("C", keyCode: 8, modifiers: [.command, .shift], in: window)
        settleLayout(window)
        #expect(session.deliveryResult?.outcome == .copied)
        #expect(session.transcript.count > 3_000)
        await session.shutdown()
    }

    private func makeWindow(model: AppModel, navigation: WindowNavigation) -> NSWindow {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 340, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MainView(model: model, session: model.coordinator,
                                                            navigationState: navigation))
        window.makeKeyAndOrderFront(nil)
        settleLayout(window)
        return window
    }

    private func settleLayout(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    }

    private func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [.command], in window: NSWindow) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                characters: characters, charactersIgnoringModifiers: characters.lowercased(),
                                                isARepeat: false, keyCode: keyCode))
        #expect(window.performKeyEquivalent(with: event))
    }
}
