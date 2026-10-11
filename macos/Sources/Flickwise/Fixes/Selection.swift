// Selection — reads and replaces the selected text of the focused app. Port of lib/ax_text.lua
// plus the ⌘C capture from lib/text_replacer.lua.
//   readDirect(_:)       Accessibility: AXSelectedText + range, no clipboard (nil when unsupported)
//   canWrite / replace   write back through AXSelectedText, verified; refuses if the text changed meanwhile
//   restore              Undo of a direct replace: reselect the result, write the original back
//   captureByCopy()      fallback: ⌘C, wait for the clipboard to change (the old clipboard is kept to restore)
// AX ranges count UTF-16 code units.
import AppKit
import ApplicationServices

struct SelectionContext {
    let text: String
    let element: AXUIElement?
    let range: CFRange?
    let app: String?
    let writable: Bool
    let web: Bool
    var newText: String?
    var newRange: CFRange?

    /// Captured with ⌘C: the clipboard as it was before, to restore afterwards.
    var savedClipboard: [NSPasteboardItem]?

    var isDirect: Bool { element != nil }
}

enum Selection {
    static func readDirect(_ s: AppSettings.Fixes) -> (SelectionContext?, String) {
        guard s.directReplace else { return (nil, "direct replace is off") }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        if let app, s.excludeApps.contains(where: { $0.caseInsensitiveCompare(app) == .orderedSame }) {
            return (nil, "excluded app")
        }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 1.0)
        guard let el: AXUIElement = TextInserter.attribute(system, kAXFocusedUIElementAttribute) else {
            return (nil, "no focused element")
        }
        if (TextInserter.attribute(el, kAXSubroleAttribute) as String?) == "AXSecureTextField" { return (nil, "secure field") }
        guard let text: String = TextInserter.attribute(el, kAXSelectedTextAttribute), !text.isEmpty else {
            return (nil, "no AX selection")
        }
        let range = selectedRange(el)
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(el, kAXSelectedTextAttribute as CFString, &settable)
        return (SelectionContext(text: text, element: el, range: range, app: app,
                                 writable: settable.boolValue && range != nil, web: TextInserter.isWebContent(el)), "")
    }

    static func canWrite(_ ctx: SelectionContext, _ s: AppSettings.Fixes) -> (Bool, String) {
        guard ctx.isDirect else { return (false, "captured with the clipboard") }
        guard ctx.writable else { return (false, "selection isn't writable through Accessibility") }
        if ctx.web && s.webContent != .direct { return (false, "web content (uses paste)") }
        return (true, "")
    }

    /// Writes `new` over the captured selection. Fails with "selection changed while working" when
    /// the user edited the text meanwhile (then nothing is overwritten).
    static func replace(_ ctx: inout SelectionContext, with new: String) -> (Bool, String) {
        guard let el = ctx.element, let range = ctx.range else { return (false, "no element") }
        guard selectExpected(el, range, ctx.text) else { return (false, "selection changed while working") }
        guard TextInserter.writeVerified(el, new, replacing: ctx.text) else { return (false, "the app ignored the write") }
        ctx.newText = new
        ctx.newRange = CFRange(location: range.location, length: new.utf16.count)
        return (true, "")
    }

    /// Undo of `replace`: puts the original back and selects it again.
    static func restore(_ ctx: SelectionContext) -> (Bool, String) {
        guard let el = ctx.element, let newRange = ctx.newRange, let newText = ctx.newText, let range = ctx.range else {
            return (false, "nothing to restore")
        }
        guard selectExpected(el, newRange, newText) else { return (false, "the replaced text was edited") }
        guard TextInserter.writeVerified(el, ctx.text, replacing: newText) else { return (false, "the app ignored the write") }
        setRange(el, CFRange(location: range.location, length: ctx.text.utf16.count))
        return (true, "")
    }

    /// ⌘C and wait (up to 2 s) for the clipboard to change. Returns nil text when nothing was copied.
    @MainActor
    static func captureByCopy() async -> SelectionContext? {
        let pb = NSPasteboard.general
        let saved = TextInserter.snapshot(pb)
        let before = pb.changeCount
        try? await Task.sleep(nanoseconds: 80_000_000)          // let the hotkey's modifiers settle
        TextInserter.sendKey(8, flags: .maskCommand)              // kVK_ANSI_C
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if pb.changeCount != before { break }
        }
        let text = pb.changeCount != before ? pb.string(forType: .string) : nil
        guard let text, !text.isEmpty else {
            TextInserter.restoreClipboard(saved)
            return nil
        }
        var ctx = SelectionContext(text: text, element: nil, range: nil,
                                   app: NSWorkspace.shared.frontmostApplication?.localizedName,
                                   writable: false, web: false)
        ctx.savedClipboard = saved
        return ctx
    }

    // ── AX helpers ───────────────────────────────────────────────────────────

    private static func selectedRange(_ el: AXUIElement) -> CFRange? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(v as! AXValue, .cfRange, &range) ? range : nil
    }

    @discardableResult
    private static func setRange(_ el: AXUIElement, _ range: CFRange) -> Bool {
        var r = range
        guard let v = AXValueCreate(.cfRange, &r) else { return false }
        return AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v) == .success
    }

    /// Makes sure `range` is selected and holds `expected` (reselects if the user moved the caret).
    private static func selectExpected(_ el: AXUIElement, _ range: CFRange, _ expected: String) -> Bool {
        if (TextInserter.attribute(el, kAXSelectedTextAttribute) as String?) == expected { return true }
        setRange(el, range)
        return (TextInserter.attribute(el, kAXSelectedTextAttribute) as String?) == expected
    }
}
