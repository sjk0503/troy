import Carbon.HIToolbox

/// The Carbon event handler is a C function pointer, so it cannot capture anything or belong to an actor.
/// It only hops to the main actor and calls the registered key.
nonisolated private func hotKeyEventHandler(
    _ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    Task { @MainActor in HotKey.current?.onPress() }
    return noErr
}

/// A global keyboard shortcut through `RegisterEventHotKey`, which needs no Accessibility permission.
final class HotKey {
    /// Control-Option-T. Not Control-Option-Space: that is the system's default for switching
    /// input sources, which people who type in two scripts use all day.
    static let defaultKeyCode = UInt32(kVK_ANSI_T)
    /// How the shortcut is written for people.
    static let defaultDisplay = "⌃⌥T"
    static let defaultModifiers = UInt32(controlKey | optionKey)

    static weak var current: HotKey?

    var onPress: () -> Void = {}
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?

    var isRegistered: Bool { reference != nil }

    /// Registers the shortcut. Returns false when the system refuses it.
    @discardableResult
    func register(keyCode: UInt32 = HotKey.defaultKeyCode, modifiers: UInt32 = HotKey.defaultModifiers) -> Bool {
        unregister()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        guard InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &spec, nil, &handler) == noErr else {
            return false
        }
        let id = EventHotKeyID(signature: OSType(0x54524F59), id: 1) // 'TROY'
        var created: EventHotKeyRef?
        guard RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &created) == noErr, let created else {
            if let handler { RemoveEventHandler(handler) }
            handler = nil
            return false
        }
        reference = created
        HotKey.current = self
        return true
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        reference = nil
        handler = nil
        if HotKey.current === self { HotKey.current = nil }
    }
}
