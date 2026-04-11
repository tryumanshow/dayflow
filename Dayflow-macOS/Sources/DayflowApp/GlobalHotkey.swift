import AppKit
import Carbon.HIToolbox

/// Registers a single global hotkey via Carbon's RegisterEventHotKey.
///
/// Carbon is deprecated but is still the most reliable cross-app hotkey path
/// for unsigned/ad-hoc-signed apps that don't want to require Accessibility
/// permissions.
///
/// Pinned to `@MainActor` so Swift 6 strict concurrency is happy — the
/// Carbon callback re-dispatches its invocation back to the main queue
/// anyway, and AppKit hotkey registration should only happen on main.
@MainActor
final class GlobalHotkey {
    static let shared = GlobalHotkey()

    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private var callback: (@MainActor () -> Void)?

    private init() {}

    func register(keyCode: UInt32 = UInt32(kVK_ANSI_I),
                  modifiers: UInt32 = UInt32(cmdKey | shiftKey),
                  handler: @escaping @MainActor () -> Void) {
        unregister()
        self.callback = handler

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData = userData else { return noErr }
            var hkID = EventHotKeyID()
            let err = GetEventParameter(event,
                                        EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID),
                                        nil,
                                        MemoryLayout<EventHotKeyID>.size,
                                        nil,
                                        &hkID)
            if err == noErr {
                // Bounce onto main — the hotkey callback touches AppKit /
                // SwiftUI state. We capture the opaque pointer as a UInt
                // to dodge Sendable checking on the closure.
                let ptrBits = UInt(bitPattern: userData)
                DispatchQueue.main.async {
                    let raw = UnsafeMutableRawPointer(bitPattern: ptrBits)!
                    let me = Unmanaged<GlobalHotkey>.fromOpaque(raw).takeUnretainedValue()
                    MainActor.assumeIsolated {
                        me.callback?()
                    }
                }
            }
            return noErr
        }, 1, &eventType, selfPtr, &eventHandler)

        let hkID = EventHotKeyID(signature: OSType(0x44464C57 /* "DFLW" */), id: 1)
        RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let h = eventHandler {
            RemoveEventHandler(h)
            eventHandler = nil
        }
    }
}
