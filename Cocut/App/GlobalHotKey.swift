import Carbon.HIToolbox
import Foundation

/// A system-wide keyboard shortcut that works while another app (the browser) is in front.
/// Uses Carbon's RegisterEventHotKey, which needs no Accessibility permission.
final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32

    private static var handlers: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false

    init?(keyCode: Int, modifiers: Int, id: UInt32, handler: @escaping () -> Void) {
        self.id = id
        Self.installHandlerIfNeeded()
        Self.handlers[id] = handler

        let hotKeyID = EventHotKeyID(signature: OSType(0x434F_4354), id: id) // 'COCT'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            Self.handlers[id] = nil
            Log.error("Couldn't register global shortcut (status \(status)); another app may be using it.")
            return nil
        }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.handlers[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let id = hotKeyID.id
            DispatchQueue.main.async { GlobalHotKey.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
