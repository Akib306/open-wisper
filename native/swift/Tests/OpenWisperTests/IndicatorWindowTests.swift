import AppKit
import SwiftUI
import Testing
import WisperCore
@testable import OpenWisper

@Suite("Nonactivating indicator window") @MainActor
struct IndicatorWindowTests {
    @Test func controlsAcceptTheFirstClickWithoutActivating() {
        let view = IndicatorHostingView(rootView: Text("Listening"))
        #expect(view.acceptsFirstMouse(for: nil))
    }

    @Test func indicatorCannotBecomeKeyOrMain() {
        let panel = NonactivatingPanel(contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
    }

    @Test(arguments: [true, false])
    func indicatorKeepsItsFrameAfterOrderingAndResizing(attached: Bool) async throws {
        _ = NSApplication.shared
        let screenFrame = NSScreen.screens.first?.frame ?? CGRect(x: -1440, y: 100, width: 1440, height: 900)
        let visibleFrame = NSScreen.screens.first?.visibleFrame ?? CGRect(x: -1440, y: 140, width: 1440, height: 835)
        let panel = NonactivatingPanel(contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isFloatingPanel = true
        defer { panel.orderOut(nil) }

        let states: [(SessionPhase, IndicatorFeedback)] = [
            (.recording, .active), (.transcribing, .active), (.idle, .review),
            (.idle, .insertionRequested), (.idle, .inserted)
        ]
        for (phase, feedback) in states {
            let layout = IndicatorLayout(screen: screenFrame, visibleFrame: visibleFrame,
                cameraWidth: attached ? 220 : 0, cameraHeight: attached ? 38 : 0,
                phase: phase, feedback: feedback)
            panel.setFrame(layout.frame, display: true)
            panel.contentView = IndicatorHostingView(rootView: Text("Listening")
                .frame(width: layout.frame.width, height: layout.frame.height))
            panel.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(30))

            #expect(panel.frame == layout.frame)
            #expect(panel.frame.minY == visibleFrame.minY + 28)
            #expect(!panel.isKeyWindow)
            #expect(!panel.isMainWindow)
        }
    }
}
