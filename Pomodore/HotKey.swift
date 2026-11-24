import AppKit
import Carbon.HIToolbox

/// A system-wide chord, registered with the window server.
///
/// Carbon's `RegisterEventHotKey` requires **no permission of any kind**: no prompt, no
/// Accessibility grant, no Input Monitoring grant, no TCC entry to be invalidated every
/// time the bundle is rebuilt with a different signature. That is the whole reason it is
/// used here in preference to `NSEvent.addGlobalMonitorForEvents`, which sees every
/// keystroke system-wide and is gated accordingly. The framework has been called legacy
/// for years and remains the supported path for exactly this.
@MainActor
final class HotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?

    /// The pointer handed to the installed handler, held *retained*.
    ///
    /// The handler is owned by the application event target rather than by this object, so
    /// it outlives deallocation. Passed unretained, dropping the last reference to a
    /// registered `HotKey` would therefore leave the handler installed over freed memory,
    /// and the next press of the chord would resolve a dangling pointer. Retaining for
    /// exactly as long as the handler is installed makes that unreachable by construction
    /// rather than by every caller remembering to `unregister()` first. Forgetting now
    /// leaks one object, which is the right direction to fail in.
    private var context: Unmanaged<HotKey>?

    /// Returns false if the chord could not be claimed, which usually means another app
    /// already holds it.
    @discardableResult
    func register(_ chord: Chord, action: @escaping () -> Void) -> Bool {
        unregister()
        self.action = action

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passRetained(self)
        self.context = context

        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            1,
            &spec,
            context.toOpaque(),
            &handler
        )
        guard installed == noErr else {
            unregister()
            return false
        }

        let registered = RegisterEventHotKey(
            chord.keyCode,
            chord.modifiers,
            EventHotKeyID(signature: OSType(0x504F_4D44), id: 1),  // 'POMD'
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard registered == noErr else {
            unregister()
            return false
        }
        return true
    }

    /// All three must come down, in this order. A registration outlives a crashed process
    /// poorly and can leave the chord claimed until login, and the retained context must
    /// not be released until the handler that holds it is gone.
    func unregister() {
        if let reference {
            UnregisterEventHotKey(reference)
            self.reference = nil
        }
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
        context?.release()
        context = nil
        action = nil
    }

    fileprivate func fire() {
        action?()
    }
}

/// A C function pointer cannot capture context, so the instance rides through `userData`
/// and comes back via `Unmanaged`. This is the only genuinely awkward part of the feature.
private let hotKeyEventHandler: EventHandlerUPP = { _, _, userData in
    guard let userData else { return noErr }
    let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async {
        MainActor.assumeIsolated { hotKey.fire() }
    }
    return noErr
}
