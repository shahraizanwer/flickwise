// TextInserter — types text at the caret of whatever app has focus.
//   1. Accessibility: set AXSelectedText on the focused element and verify it changed
//      (clipboard untouched). Skipped for web content (browsers, Electron apps), where
//      writing the DOM directly bypasses the page's input events.
//   2. Otherwise paste: put the text on the clipboard, send ⌘V, then restore the
//      previous clipboard. The temporary item is marked transient so clipboard
//      managers ignore it.
//   3. No focused element at all: copy to the clipboard and say so.
import AppKit
import ApplicationServices

enum TextInserter {
    enum Outcome { case direct, pasted, copied }

    static func insert(_ text: String) -> Outcome {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 1.0)    // a hung app mustn't freeze us for the default 6 s
        guard let el: AXUIElement = attribute(system, kAXFocusedUIElementAttribute) else {
            copyToClipboard(text)
            return .copied
        }
        if let why = cannotWriteDirectly(el) {
            Log.debug("Insert by paste: \(why)")
            paste(text)
            return .pasted
        }
        if writeVerified(el, text) { return .direct }
        paste(text)
        return .pasted
    }

    static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // ── Accessibility ───────────────────────────────────────────────────────

    private static func cannotWriteDirectly(_ el: AXUIElement) -> String? {
        if (attribute(el, kAXSubroleAttribute) as String?) == "AXSecureTextField" { return "secure field" }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(el, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return "not editable through Accessibility" }
        if isWebContent(el) { return "web content" }
        return nil
    }

    private static func isWebContent(_ el: AXUIElement) -> Bool {
        if (attribute(el, "AXDOMIdentifier") as AnyObject?) != nil || (attribute(el, "AXDOMClassList") as AnyObject?) != nil {
            return true
        }
        var cur: AXUIElement? = el
        for _ in 0..<40 {
            guard let c = cur else { return false }
            if (attribute(c, kAXRoleAttribute) as String?) == "AXWebArea" { return true }
            cur = attribute(c, kAXParentAttribute)
        }
        return false
    }

    private static func writeVerified(_ el: AXUIElement, _ text: String) -> Bool {
        let before: String? = attribute(el, kAXValueAttribute)
        let countBefore: Int? = attribute(el, kAXNumberOfCharactersAttribute)
        let selected: String = attribute(el, kAXSelectedTextAttribute) ?? ""
        guard AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
            return false
        }
        if let before, let after: String = attribute(el, kAXValueAttribute) {
            return after != before          // changed (maybe normalized): never insert twice
        }
        if let countBefore, let countAfter: Int = attribute(el, kAXNumberOfCharactersAttribute) {
            return !(countAfter == countBefore && text.utf16.count != selected.utf16.count)
        }
        return true
    }

    private static func attribute<T>(_ el: AXUIElement, _ name: String) -> T? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        if T.self == AXUIElement.self {
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! T)
        }
        return value as? T
    }

    // ── paste ───────────────────────────────────────────────────────────────

    private static func paste(_ text: String) {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pb.writeObjects([item])
        let changeCount = pb.changeCount

        sendCommandV()
        // Give the target app time to read the clipboard before restoring it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard pb.changeCount == changeCount else { return }   // someone copied meanwhile: leave it
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
    }

    private static func snapshot(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        (pb.pasteboardItems ?? []).map { old in
            let copy = NSPasteboardItem()
            for type in old.types {
                if let data = old.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    private static func sendCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9   // kVK_ANSI_V
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
