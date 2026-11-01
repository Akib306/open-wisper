import Carbon
import WisperCore

/// Carbon registration needs no Input Monitoring permission or global event tap.
@MainActor public final class GlobalHotkey: HotkeyRegistration {
    public private(set) var combination: HotkeyCombination?
    public var onPress: (@MainActor () -> Void)?
    private var registration: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var registrationID: UInt32 = 0
    private var pressed = false
    private static let signature: OSType = 0x4F575350 // OWSP

    public init() throws {
        var events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr else { return status }
            // Application EventTarget dispatches this handler on the main thread.
            return MainActor.assumeIsolated {
                let owner = Unmanaged<GlobalHotkey>.fromOpaque(context).takeUnretainedValue()
                guard identifier.signature == GlobalHotkey.signature, identifier.id == owner.registrationID else {
                    return OSStatus(eventNotHandledErr)
                }
                if GetEventKind(event) == UInt32(kEventHotKeyReleased) { owner.pressed = false }
                else if !owner.pressed { owner.pressed = true; owner.onPress?() }
                return noErr
            }
        }, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { throw WisperError.message("The global shortcut handler could not start (\(status)). Recording from the menu is still available.") }
    }

    public func replace(with combination: HotkeyCombination) throws {
        try combination.validate()
        if self.combination == combination, registration != nil { return }
        let nextID = registrationID &+ 1
        var replacement: EventHotKeyRef?
        var modifiers: UInt32 = 0
        if combination.modifiers.contains(.command) { modifiers |= UInt32(cmdKey) }
        if combination.modifiers.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if combination.modifiers.contains(.control) { modifiers |= UInt32(controlKey) }
        if combination.modifiers.contains(.option) { modifiers |= UInt32(optionKey) }
        let status = RegisterEventHotKey(combination.keyCode, modifiers,
                                        EventHotKeyID(signature: Self.signature, id: nextID),
                                        GetApplicationEventTarget(), 0, &replacement)
        guard status == noErr, let replacement else {
            throw WisperError.message("\(combination.displayName) is unavailable, possibly in another dictation app. Choose another shortcut. Your previous shortcut is still registered.")
        }
        // Acquire the new registration first. A conflict never releases the old one.
        if let registration {
            let releaseStatus = UnregisterEventHotKey(registration)
            guard releaseStatus == noErr else {
                UnregisterEventHotKey(replacement)
                throw WisperError.message("Couldn’t replace the shortcut. The previous shortcut is still active.")
            }
        }
        registration = replacement
        registrationID = nextID
        pressed = false
        self.combination = combination
    }

    public func invalidate() {
        if let registration { UnregisterEventHotKey(registration) }
        if let handler { RemoveEventHandler(handler) }
        registration = nil
        handler = nil
        combination = nil
    }
}
