import AppKit
import WisperCore

/// A bounded, memory-only clipboard transaction. The change count AND our random
/// marker must still match before restoration; another app's newer copy wins.
@MainActor final class ClipboardPaster {
    static let markerType = NSPasteboard.PasteboardType("dev.akib.openwisper.paste-session")
    private let pasteboard: NSPasteboard
    private let maximumBytes: Int
    private let requestTimeout: Duration
    private let settle: @MainActor () async -> Void

    init(pasteboard: NSPasteboard = .general, maximumBytes: Int = 8 * 1_024 * 1_024,
         requestTimeout: Duration = .seconds(2),
         settle: @escaping @MainActor () async -> Void = {
             try? await Task.sleep(for: .milliseconds(500))
         }) {
        self.pasteboard = pasteboard
        self.maximumBytes = maximumBytes
        self.requestTimeout = requestTimeout
        self.settle = settle
    }

    func paste(_ text: String, revalidate: () -> Bool, send: () -> Void) async -> DeliveryResult {
        guard !Task.isCancelled, revalidate() else { return blocked() }
        let originalCount = pasteboard.changeCount
        guard let original = snapshot(), pasteboard.changeCount == originalCount else {
            return DeliveryResult(.blocked, "The clipboard could not be preserved safely. Your transcript is ready to copy.")
        }
        let marker = UUID().uuidString
        let item = NSPasteboardItem()
        let provider = ClipboardTextProvider(text: text)
        guard item.setDataProvider(provider, forTypes: [.string]), item.setString(marker, forType: Self.markerType),
              !Task.isCancelled, revalidate(), pasteboard.changeCount == originalCount else { return blocked() }
        let clearedCount = pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            let failedCount = pasteboard.changeCount
            if failedCount == clearedCount || (pasteboard.string(forType: Self.markerType) == marker &&
                pasteboard.changeCount == failedCount) { restore(original) }
            return DeliveryResult(.failed, "Couldn’t prepare Paste. Your transcript is ready to copy.")
        }
        let ownedCount = pasteboard.changeCount
        defer {
            if ownsClipboard(count: ownedCount, marker: marker) { restore(original) }
        }
        // Recheck after clipboard work and immediately before posting the pair.
        guard !Task.isCancelled, revalidate(), pasteboard.changeCount == ownedCount,
              pasteboard.string(forType: Self.markerType) == marker else { return blocked() }
        send()
        let deadline = ContinuousClock.now.advanced(by: requestTimeout)
        while !provider.hasProvidedData, !Task.isCancelled, ContinuousClock.now < deadline,
              ownsClipboard(count: ownedCount, marker: marker) {
            do { try await Task.sleep(for: .milliseconds(20)) }
            catch { break }
        }
        guard provider.hasProvidedData else {
            return DeliveryResult(.insertionRequested, "Paste was requested, but no clipboard read was observed. Check the destination before copying to avoid a duplicate.")
        }
        guard !Task.isCancelled, ownsClipboard(count: ownedCount, marker: marker) else {
            return DeliveryResult(.insertionRequested, "Paste was requested. Check the destination before inserting again.")
        }
        await settle()
        return DeliveryResult(.insertionRequested, "Paste sent to your cursor. Check the destination before inserting again.")
    }

    private func ownsClipboard(count: Int, marker: String) -> Bool {
        pasteboard.changeCount == count && pasteboard.string(forType: Self.markerType) == marker &&
            pasteboard.changeCount == count
    }

    private func snapshot() -> [NSPasteboardItem]? {
        guard let items = pasteboard.pasteboardItems else {
            return (pasteboard.types?.isEmpty ?? true) ? [] : nil
        }
        guard items.count <= 16 else { return nil }
        var total = 0
        var saved: [NSPasteboardItem] = []
        for item in items {
            guard item.types.count <= 32,
                  !item.types.contains(where: { $0.rawValue.lowercased().contains("promise") }) else { return nil }
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type), data.count <= maximumBytes - total else { return nil }
                total += data.count
                guard copy.setData(data, forType: type) else { return nil }
            }
            saved.append(copy)
        }
        return saved
    }

    private func restore(_ items: [NSPasteboardItem]) {
        pasteboard.clearContents()
        if !items.isEmpty { _ = pasteboard.writeObjects(items) }
    }

    private func blocked() -> DeliveryResult {
        DeliveryResult(.blocked, "The destination or clipboard changed before Paste. Your transcript is ready to copy.")
    }
}

private final class ClipboardTextProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private let text: String
    private let lock = NSLock()
    private var provided = false

    init(text: String) { self.text = text }

    var hasProvidedData: Bool { lock.withLock { provided } }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .string, item.setString(text, forType: type) else { return }
        lock.withLock { provided = true }
    }
}
