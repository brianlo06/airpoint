import AppKit
import Carbon.HIToolbox

/// A system-wide ⌃⌥⌘⎋ for panic disconnect.
///
/// Panic is only worth having if it works when the menu bar is out of reach — and a
/// misbehaving session is exactly the situation in which reaching the panel needs the
/// very cursor that is misbehaving. Carbon's hot-key API is old, but it is the one
/// mechanism that fires with any app focused while needing no event tap and no extra
/// permission. The combination deliberately includes all three modifiers so it cannot
/// collide with anything a user types by accident, and ⎋ because that is the key people
/// already reach for when they want something to stop.
///
/// Registered only while the server is running: an idle app has nothing to disconnect
/// and no business holding a global key combination.
final class PanicHotKey {

    /// Shown in the UI next to the panic button, so the shortcut is discoverable in the
    /// one place a person looks when they care about disconnecting.
    static let displayString = "⌃⌥⌘⎋"

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        // The C callback cannot capture Swift context, so `self` travels as userData.
        // Unretained is safe: deinit removes the handler before the reference dies.
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<PanicHotKey>.fromOpaque(userData).takeUnretainedValue().fire()
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x4152_5054) /* "ARPT" */, id: 1)
        RegisterEventHotKey(UInt32(kVK_Escape),
                            UInt32(controlKey | optionKey | cmdKey),
                            hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
    }

    private func fire() {
        // Carbon delivers on the main thread, but the model is main-actor-isolated and
        // the compiler cannot see that from here; hop explicitly rather than assert.
        let action = self.action
        DispatchQueue.main.async { action() }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
