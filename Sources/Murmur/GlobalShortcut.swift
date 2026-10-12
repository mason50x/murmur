import Carbon.HIToolbox
import Foundation

/// A system-wide key combo registered through Carbon so the keystroke is consumed (⌃⌘V → paste last).
final class GlobalShortcut {
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    nonisolated(unsafe) private static var registry: [UInt32: GlobalShortcut] = [:]
    nonisolated(unsafe) private static var nextID: UInt32 = 1

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action
        let id = Self.nextID
        Self.nextID += 1
        Self.registry[id] = self

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hk = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hk)
                if let shortcut = GlobalShortcut.registry[hk.id] {
                    DispatchQueue.main.async { shortcut.action() }
                }
                return noErr
            }, 1, &spec, nil, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x4D55_524D), id: id)  // 'MURM'
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
