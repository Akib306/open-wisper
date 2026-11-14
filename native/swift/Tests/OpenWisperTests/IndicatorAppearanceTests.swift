import AppKit
import SwiftUI
import Testing
import WisperCore
@testable import OpenWisper

@Suite("Bottom indicator appearance") @MainActor
struct IndicatorAppearanceTests {
    @Test(arguments: [true, false])
    func renderedShellIsPetrolOnEveryDisplay(hasCamera: Bool) throws {
        _ = NSApplication.shared
        let layout = IndicatorLayout(screen: CGRect(x: 0, y: 0, width: 1800, height: 1169),
            visibleFrame: CGRect(x: 0, y: 0, width: 1800, height: 1130),
            cameraWidth: hasCamera ? 220 : 0, cameraHeight: hasCamera ? 38 : 0)
        let view = IndicatorHostingView(rootView: RecordingIndicatorView(session: UIPreview.makeSession(),
            layout: layout, feedback: .active, setupRequired: false,
            stop: {}, cancel: {}, review: {}, copy: {}, dismiss: {}))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: layout.frame.size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = view
        defer { window.orderOut(nil) }
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 2)?.usingColorSpace(.sRGB))
        #expect(color.alphaComponent > 0.99)
        #expect(color.greenComponent > color.redComponent)
        #expect(color.blueComponent > color.redComponent)
    }
}
