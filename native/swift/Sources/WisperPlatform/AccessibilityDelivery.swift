import AppKit
import ApplicationServices
import Carbon
import WisperCore

struct FocusedTextTarget {
    let element: AXUIElement
    let context: InsertionContext
    let supportsSelectedText: Bool
    let isWebContent: Bool

    init(element: AXUIElement, context: InsertionContext, supportsSelectedText: Bool, isWebContent: Bool = false) {
        self.element = element
        self.context = context
        self.supportsSelectedText = supportsSelectedText
        self.isWebContent = isWebContent
    }
}

@MainActor protocol TextInsertionSystem: AnyObject {
    var accessibilityGranted: Bool { get }
    var focusFailureReason: String? { get }
    var focusMetadata: [String: String] { get }
    func prepareForDictation()
    func focusedTarget() -> FocusedTextTarget?
    func replaceSelection(_ text: String, in target: FocusedTextTarget) -> AXError
    func preparePaste(to processID: Int32) -> (() -> Void)?
}

/// A single-use destination captured at Stop. Unsupported editors use one
/// targeted Command-V. Neither path activates an app, submits, or retries ambiguity.
@MainActor public final class AccessibilityDelivery: Delivery {
    private var target: (token: TargetToken, field: FocusedTextTarget)?
    private let system: any TextInsertionSystem
    private let paster: ClipboardPaster
    private var snapshotFailureReason: String?

    public convenience init() {
        self.init(system: NativeTextInsertionSystem(), paster: ClipboardPaster())
    }

    init(system: any TextInsertionSystem, paster: ClipboardPaster) {
        self.system = system
        self.paster = paster
    }

    public func prepareForDictation() { system.prepareForDictation() }

    /// Reads metadata only. Does not mutate the active session's saved target.
    public func readiness() -> (granted: Bool, eligible: Bool, reason: String?, metadata: [String: String]) {
        guard system.accessibilityGranted else { return (false, false, "Accessibility permission is unavailable.", [:]) }
        guard let field = system.focusedTarget() else { return (true, false, system.focusFailureReason, system.focusMetadata) }
        let reason = blockedReason(saved: field, current: field, text: "")
        return (true, reason == nil, reason, system.focusMetadata)
    }

    public func snapshot() -> TargetToken? {
        target = nil
        snapshotFailureReason = nil
        guard system.accessibilityGranted else { return nil }
        guard let field = system.focusedTarget() else {
            snapshotFailureReason = system.focusFailureReason
            return nil
        }
        if let reason = blockedReason(saved: field, current: field, text: "") {
            snapshotFailureReason = reason
            return nil
        }
        let token = TargetToken()
        target = (token, field)
        return token
    }

    public func deliver(_ text: String, to token: TargetToken?) async -> DeliveryResult {
        let saved = target
        target = nil
        guard !Task.isCancelled else { return DeliveryResult(.cancelled, "Dictation cancelled.") }
        guard system.accessibilityGranted else {
            return DeliveryResult(.blocked, "Enable Accessibility in Open Wisper’s Settings to insert at your cursor. Your transcript is ready to copy.")
        }
        guard let saved, saved.token == token else {
            return DeliveryResult(.blocked, snapshotFailureReason ?? "No editable field was focused when recording stopped. Your transcript is ready to copy.")
        }
        guard let current = validatedTarget(saved.field, text: text) else {
            return DeliveryResult(.blocked, "The focused field or selection changed. Your transcript is ready to copy.")
        }
        if current.supportsSelectedText && !current.isWebContent {
            switch system.replaceSelection(text, in: current) {
            case .success:
                return DeliveryResult(.insertionRequested, "Sent to your cursor. Check the destination before inserting again.")
            case .cannotComplete:
                return DeliveryResult(.insertionRequested, "The editor did not confirm the request. Check it before copying to avoid a duplicate.")
            case .attributeUnsupported, .notImplemented:
                break // Definitively unsupported: no write was requested.
            default:
                return DeliveryResult(.blocked, "The editor declined insertion. Your transcript is ready to copy.")
            }
        }
        guard let sendPaste = system.preparePaste(to: saved.field.context.processID) else {
            return DeliveryResult(.blocked, "macOS could not send Paste. Check Accessibility access in Settings, or copy your transcript.")
        }
        return await paster.paste(text, revalidate: { [self] in
            validatedTarget(saved.field, text: text) != nil
        }, send: sendPaste)
    }

    public func copy(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    public func discardTarget() { target = nil }

    private func validatedTarget(_ saved: FocusedTextTarget, text: String) -> FocusedTextTarget? {
        guard !Task.isCancelled, system.accessibilityGranted, let current = system.focusedTarget(),
              blockedReason(saved: saved, current: current, text: text) == nil else { return nil }
        return current
    }

    private func blockedReason(saved: FocusedTextTarget, current: FocusedTextTarget, text: String) -> String? {
        DeliveryPolicy.blockedReason(snapshot: saved.context, current: current.context,
            sameElement: CFEqual(saved.element, current.element),
            ownProcessID: ProcessInfo.processInfo.processIdentifier, text: text)
    }
}

@MainActor private final class NativeTextInsertionSystem: TextInsertionSystem {
    var accessibilityGranted: Bool { AXIsProcessTrusted() }
    private(set) var focusFailureReason: String?
    private(set) var focusMetadata: [String: String] = [:]

    func prepareForDictation() {
        guard accessibilityGranted, let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier, !app.isTerminated else { return }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        // Electron's documented assistive-technology handshake. Ask at Start so
        // its renderer can prepare focus/selection metadata before Stop.
        _ = AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    func replaceSelection(_ text: String, in target: FocusedTextTarget) -> AXError {
        AXUIElementSetAttributeValue(target.element, kAXSelectedTextAttribute as CFString, text as CFString)
    }

    func preparePaste(to processID: Int32) -> (() -> Void)? {
        guard CGPreflightPostEventAccess(),
              let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else { return nil }
        down.flags = .maskCommand
        up.flags = .maskCommand
        return {
            down.postToPid(processID)
            up.postToPid(processID)
        }
    }

    private func unavailable(_ reason: String) -> FocusedTextTarget? {
        focusFailureReason = reason
        return nil
    }

    func focusedTarget() -> FocusedTextTarget? {
        focusFailureReason = nil
        focusMetadata = [:]
        guard accessibilityGranted else { return unavailable("Accessibility permission is unavailable.") }
        guard !IsSecureEventInputEnabled() else { return unavailable("Automatic insertion is unavailable while secure keyboard input is active.") }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !app.isTerminated, let started = app.launchDate, let bundle = app.bundleIdentifier else {
            return unavailable("Place the cursor in another app before stopping dictation.")
        }
        focusMetadata["frontmostBundle"] = bundle
        let application = AXUIElementCreateApplication(app.processIdentifier)
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(application, 0.25)
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        func candidate(in root: AXUIElement, metadataKey: String) -> FocusedElementResolver.Candidate? {
            guard let element = elementAttribute(root, kAXFocusedUIElementAttribute) else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.25)
            let role = stringAttribute(element, kAXRoleAttribute)
            focusMetadata[metadataKey] = role ?? "unavailable"
            var pid: pid_t = 0
            let processID = AXUIElementGetPid(element, &pid) == .success ? pid : nil
            return .init(element: element, processID: processID, role: role)
        }
        let global = candidate(in: systemWide, metadataKey: "systemFocusedRole")
        let local = candidate(in: application, metadataKey: "applicationFocusedRole")
        guard let resolved = FocusedElementResolver.resolve(systemWide: global, application: local,
            processID: app.processIdentifier), let role = resolved.role else {
            return unavailable("No editable text field was focused when recording stopped.")
        }
        let element = resolved.element
        guard let range = selectionRange(element) else {
            return unavailable("The editor did not expose its cursor selection to Accessibility.")
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == app.processIdentifier else { return unavailable("The editor changed while checking its focused field.") }
        let selectedText = isSettable(element, kAXSelectedTextAttribute)
        // Browsers can expose an editable value without AXSelectedText support.
        // Query editability only; never read or replace the whole document value.
        let editable = selectedText || isSettable(element, kAXValueAttribute) ||
            attribute(element, "AXEditable").map { CFEqual($0, kCFBooleanTrue) } == true
        let enabled = attribute(element, kAXEnabledAttribute).map { CFEqual($0, kCFBooleanTrue) } ?? false
        guard let ancestry = secureAncestry(element) else { return unavailable("The editor did not expose whether this field is secure.") }
        return FocusedTextTarget(element: element,
            context: InsertionContext(processID: pid, processStartedAt: started, bundleID: bundle,
                role: role, selectionLocation: range.location, selectionLength: range.length,
                editable: enabled && editable, secure: ancestry.secure), supportsSelectedText: selectedText,
            isWebContent: ancestry.webContent)
    }

    private func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var writable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &writable) == .success && writable.boolValue
    }

    private func secureAncestry(_ element: AXUIElement) -> (secure: Bool, webContent: Bool)? {
        var depth = 0
        var roles: [String] = []
        var webContent = false
        defer {
            focusMetadata["securityAncestorCount"] = String(depth)
            focusMetadata["securityAncestorRoles"] = roles.joined(separator: ",")
        }
        let secure = AncestrySecurityResolver.isSecure(from: element, same: CFEqual) { current in
            depth += 1
            AXUIElementSetMessagingTimeout(current, 0.05)
            guard let role = stringAttribute(current, kAXRoleAttribute) else {
                focusMetadata["securityFailure"] = "ancestor role unavailable"
                return nil
            }
            if role == "AXWebArea" { webContent = true }
            if roles.count < 48 { roles.append(String(role.prefix(32))) }
            let secure = stringAttribute(current, kAXSubroleAttribute) == kAXSecureTextFieldSubrole
            let root = role == kAXApplicationRole || role == kAXWindowRole
            let parent = secure || root ? nil : elementAttribute(current, kAXParentAttribute)
            if !secure && !root && parent == nil { focusMetadata["securityFailure"] = "ancestor parent unavailable" }
            return .init(role: role, secure: secure, parent: parent)
        }
        guard let secure else { return nil }
        return (secure, webContent)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func stringAttribute(_ element: AXUIElement, _ name: String) -> String? { attribute(element, name) as? String }

    private func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func selectionRange(_ element: AXUIElement) -> CFRange? {
        guard let value = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return range
    }
}
