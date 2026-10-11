// GlobalHotkeys — system-wide shortcuts through Carbon's RegisterEventHotKey (no Accessibility
// needed, and the key press is consumed so the app underneath never sees it).
//   register(_ combos: [(KeyCombo, action)])   replaces every registration
// A combo that another app already owns fails to register; that's logged and reported.
import Carbon.HIToolbox
import Foundation

final class GlobalHotkeys {
    static let shared = GlobalHotkeys()

    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?
    private(set) var failed: [String] = []

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let action = GlobalHotkeys.shared.actions[id.id]
            DispatchQueue.main.async { action?() }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    func register(_ entries: [(combo: KeyCombo, label: String, action: () -> Void)]) {
        unregisterAll()
        failed = []
        for (i, e) in entries.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x464C_4B57), id: UInt32(i + 1))   // 'FLKW'
            let status = RegisterEventHotKey(UInt32(e.combo.keyCode), e.combo.carbonModifiers, id,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                actions[id.id] = e.action
            } else {
                failed.append("\(e.label) (\(e.combo.display))")
            }
        }
        if !failed.isEmpty { Log.info("Hotkeys taken by another app: \(failed.joined(separator: ", "))") }
        Log.info("Registered \(refs.count) hotkeys")
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        actions = [:]
    }
}
