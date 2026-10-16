// TextInserter — types text at the caret of whatever app has focus.
//   1. Accessibility: set AXSelectedText on the focused element and verify it changed
//      (clipboard untouched). Skipped for web content (browsers, Electron apps), where
//      writing the DOM directly bypasses the page's input events, for terminals, which can
//      draw the text without sending it to the program running in them, and for the apps
//      listed under "Always use copy/paste in".
//   2. Otherwise paste: put the text on the clipboard, send ⌘V, then restore the
//      previous clipboard. The temporary item is marked transient so clipboard
//      managers ignore it.
//   3. No focused element at all: copy to the clipboard and say so.
import AppKit
import ApplicationServices

enum TextInserter {
    enum Outcome { case direct, pasted, copied }

    static func insert(_ text: String, alwaysPasteIn apps: [String] = []) -> Outcome {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 1.0)    // a hung app mustn't freeze us for the default 6 s
        guard let el: AXUIElement = attribute(system, kAXFocusedUIElementAttribute) else {
            copyToClipboard(text)
            return .copied
        }
        if let why = cannotWriteDirectly(el, alwaysPasteIn: apps) {
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

    private static func cannotWriteDirectly(_ el: AXUIElement, alwaysPasteIn apps: [String]) -> String? {
        if (attribute(el, kAXSubroleAttribute) as String?) == "AXSecureTextField" { return "secure field" }
        var pid: pid_t = 0
        if AXUIElementGetPid(el, &pid) == .success, let app = NSRunningApplication(processIdentifier: pid) {
            if isTerminal(app) { return "terminal" }
            if let name = app.localizedName, apps.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                return "copy/paste app"
            }
        }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(el, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return "not editable through Accessibility" }
        if isWebContent(el) { return "web content" }
        return nil
    }

    /// Terminal emulators: an Accessibility write can show up on screen without reaching the
    /// shell or the program running in it (it vanishes on the next redraw), so always paste.
    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "dev.warp.Warp", "com.github.wez.wezterm", "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty",
        "co.zeit.hyper", "org.tabby", "com.raphaelamorim.rio",
    ]

    static func isTerminal(_ app: NSRunningApplication?) -> Bool {
        guard let id = app?.bundleIdentifier else { return false }
        return terminalBundleIDs.contains(id)
    }

    static func isWebContent(_ el: AXUIElement) -> Bool {
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

    static func writeVerified(_ el: AXUIElement, _ text: String, replacing old: String? = nil) -> Bool {
        let before: String? = attribute(el, kAXValueAttribute)
        let countBefore: Int? = attribute(el, kAXNumberOfCharactersAttribute)
        let selected: String = old ?? attribute(el, kAXSelectedTextAttribute) ?? ""
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

    static func attribute<T>(_ el: AXUIElement, _ name: String) -> T? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        if T.self == AXUIElement.self {
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! T)
        }
        return value as? T
    }

    // ── paste ───────────────────────────────────────────────────────────────

    /// Pastes `text`, then restores the clipboard to `restoring` (default: what it held before).
    static func paste(_ text: String, restoring: [NSPasteboardItem]? = nil) {
        let pb = NSPasteboard.general
        let saved = restoring ?? snapshot(pb)
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

    static func snapshot(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        (pb.pasteboardItems ?? []).map { old in
            let copy = NSPasteboardItem()
            for type in old.types {
                if let data = old.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    static func sendCommandV() { sendKey(9, flags: .maskCommand) }   // kVK_ANSI_V

    /// Posts one key press (down + up) with exactly these modifier flags.
    static func sendKey(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }

    static func restoreClipboard(_ items: [NSPasteboardItem]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if !items.isEmpty { pb.writeObjects(items) }
    }
}
