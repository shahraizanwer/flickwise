// HotkeyMonitor — watches one modifier key system-wide (hold-to-talk).
//
// A persistent, listen-only-in-spirit CGEventTap on flagsChanged reports
// press / release of the trigger. It never swallows modifier events.
// While a session is active, a second tap on keyDown reports other keys
// (a chord like Right⌘+C means "not dictation") and swallows Esc to cancel.
// Both taps need the Accessibility permission.
import AppKit
import CoreGraphics

final class HotkeyMonitor {
    enum Event {
        case pressed        // the trigger went down with no other modifier held
        case released       // the trigger went up
        case chord          // another modifier or key joined while the trigger was down
        case escape         // Esc while a session is active (swallowed)
    }

    var trigger: TriggerKey
    var onEvent: ((Event) -> Void)?
    /// Asked on every key press during a session: should Esc be swallowed now?
    var escapeIsOurs: () -> Bool = { true }

    private var flagsTap: CFMachPort?
    private var flagsSource: CFRunLoopSource?
    private var keyTap: CFMachPort?
    private var keySource: CFRunLoopSource?
    private var triggerDown = false

    init(trigger: TriggerKey) {
        self.trigger = trigger
    }

    var isRunning: Bool { flagsTap != nil }

    /// Starts the modifier tap. Returns false when Accessibility isn't granted yet.
    @discardableResult
    func start() -> Bool {
        if flagsTap != nil { return true }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = makeTap(mask: mask, callback: { _, type, event, refcon in
            let me = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
            me.handleFlags(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }) else { return false }
        flagsTap = tap
        flagsSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), flagsSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.info("Hotkey monitor started (hold \(trigger.short))")
        return true
    }

    func stop() {
        stopKeyTap()
        if let tap = flagsTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = flagsSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        flagsTap = nil
        flagsSource = nil
        triggerDown = false
    }

    /// Watch other keys while a session is active (chord detection and Esc).
    func startKeyTap() {
        if keyTap != nil { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = makeTap(mask: mask, callback: { _, type, event, refcon in
            let me = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
            return me.handleKey(type: type, event: event)
        }) else { return }
        keyTap = tap
        keySource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), keySource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stopKeyTap() {
        if let tap = keyTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = keySource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        keyTap = nil
        keySource = nil
    }

    // ── private ──────────────────────────────────────────────────────────────

    private func makeTap(mask: CGEventMask, callback: CGEventTapCallBack) -> CFMachPort? {
        CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                          eventsOfInterest: mask, callback: callback,
                          userInfo: Unmanaged.passUnretained(self).toOpaque())
    }

    private func reenable(_ type: CGEventType) -> Bool {
        guard type == .tapDisabledByTimeout || type == .tapDisabledByUserInput else { return false }
        if let tap = flagsTap { CGEvent.tapEnable(tap: tap, enable: true) }
        if let tap = keyTap { CGEvent.tapEnable(tap: tap, enable: true) }
        Log.info("Event tap was disabled by the system — re-enabled")
        return true
    }

    private func handleFlags(type: CGEventType, event: CGEvent) {
        if reenable(type) { return }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let raw = event.flags.rawValue
        if code != trigger.keyCode {
            // Another modifier changed while ours is held: a shortcut, not dictation.
            if triggerDown { onEvent?(.chord) }
            return
        }
        let down = raw & trigger.deviceMask != 0
        if down == triggerDown { return }
        triggerDown = down
        if down {
            let others: [CGEventFlags] = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]
                .filter { $0 != trigger.genericFlag }
            // The fn flag is also set by arrow and function keys; only count it for real modifier holds.
            if others.contains(where: { event.flags.contains($0) && $0 != .maskSecondaryFn }) { return }
            onEvent?(.pressed)
        } else {
            onEvent?(.released)
        }
    }

    private func handleKey(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if reenable(type) { return Unmanaged.passUnretained(event) }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if code == 53, escapeIsOurs() {   // kVK_Escape
            onEvent?(.escape)
            return nil
        }
        if triggerDown { onEvent?(.chord) }
        return Unmanaged.passUnretained(event)
    }
}
