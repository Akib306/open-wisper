import Foundation

/// Metadata only: no document contents, selected text, URLs, or clipboard history.
public struct InsertionContext: Equatable, Sendable {
    public var processID: Int32
    public var processStartedAt: Date
    public var bundleID: String
    public var role: String
    public var selectionLocation: Int
    public var selectionLength: Int
    public var editable: Bool
    public var secure: Bool

    public init(processID: Int32, processStartedAt: Date, bundleID: String, role: String,
                selectionLocation: Int, selectionLength: Int, editable: Bool, secure: Bool) {
        self.processID = processID
        self.processStartedAt = processStartedAt
        self.bundleID = bundleID
        self.role = role
        self.selectionLocation = selectionLocation
        self.selectionLength = selectionLength
        self.editable = editable
        self.secure = secure
    }
}

public enum DeliveryPolicy {
    private static let terminalBundles: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp", "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty"
    ]

    public static func blockedReason(snapshot: InsertionContext, current: InsertionContext,
                                     sameElement: Bool, ownProcessID: Int32, text: String) -> String? {
        if snapshot.processID == ownProcessID { return "Place the cursor in another app before stopping dictation. Your transcript is available to copy." }
        if snapshot.secure || current.secure { return "Automatic insertion is unavailable in secure fields. Review the transcript here." }
        if !sameElement || snapshot != current { return "The focused field or selection changed. Review and copy your transcript instead." }
        if !snapshot.editable || !["AXTextField", "AXTextArea"].contains(snapshot.role) || snapshot.selectionLocation < 0 || snapshot.selectionLength < 0 {
            return "This field does not expose an editable text selection. Use Copy instead."
        }
        if terminalBundles.contains(snapshot.bundleID) {
            return "Automatic insertion is disabled in terminals. Review the text before copying it."
        }
        if text.unicodeScalars.contains(where: { ($0.value < 32 && $0.value != 10 && $0.value != 9) || (127...159).contains($0.value) }) {
            return "The transcript contains control characters. Review it and use Copy if appropriate."
        }
        return nil
    }
}
