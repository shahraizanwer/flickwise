// ModePicker — the command palette (⌘⇧P by default). Port of lib/mode_picker.lua.
// Captures the selection first (Accessibility, else ⌘C), then shows every enabled mode with
// its number and shortcut under the notch island. Keys come from a session EventTap, so the
// app you're in keeps focus:
//   type to filter · ↑/↓ · Return runs · 1–9 runs that row (when the filter is empty) · Esc closes.
// A click on a row runs it. The chosen mode gets the already-captured selection.
import AppKit
import SwiftUI

final class PickerModel: ObservableObject {
    @Published var query = ""
    @Published var selected = 0
    @Published var preview = ""
    @Published var visible = false

    var all: [Mode] = []
    var filtered: [Mode] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { $0.name.lowercased().contains(q) }
    }
}

@MainActor
final class ModePicker {
    static let shared = ModePicker()

    let model = PickerModel()
    private var panel: NSPanel?
    private var tap: EventTap?
    private var ctx: SelectionContext?

    var isOpen: Bool { model.visible }

    func open() {
        guard !isOpen else { close(); return }
        guard !FixController.shared.inFlight else { HUD.shared.info("Still working on the last one…"); return }
        ResultCard.shared.dismiss()
        Task {
            guard let captured = await FixController.shared.capture() else {
                HUD.shared.error("Select some text first")
                return
            }
            ctx = captured
            model.all = ModeStore.shared.enabledModes
            model.query = ""
            model.selected = 0
            model.preview = captured.text.replacingOccurrences(of: "\n", with: " ")
            show()
        }
    }

    func close(restoreClipboard: Bool = true) {
        tap?.stop(); tap = nil
        if restoreClipboard, let saved = ctx?.savedClipboard { TextInserter.restoreClipboard(saved) }
        guard model.visible else { return }
        withAnimation(.easeIn(duration: 0.12)) { model.visible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
            if self?.model.visible == false { self?.panel?.orderOut(nil) }
        }
    }

    func run(_ mode: Mode) {
        guard let ctx else { return }
        close(restoreClipboard: false)                   // FixController restores it after the fix
        self.ctx = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { FixController.shared.run(mode, with: ctx) }
    }

    // ── private ──────────────────────────────────────────────────────────────

    private func show() {
        let panel = self.panel ?? makePanel()
        let host = panel.contentView as! NSHostingView<PickerView>
        host.layoutSubtreeIfNeeded()
        let size = NSSize(width: 440, height: min(520, host.fittingSize.height))
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
            let f = screen.frame, v = screen.visibleFrame
            let y = SettingsStore.shared.settings.dictation.indicator == .notch
                ? f.maxY - (NotchHUD.notchSize(of: screen)?.height ?? (f.maxY - v.maxY)) - 16 - size.height
                : v.minY + 64
            panel.setFrame(NSRect(x: f.midX - size.width / 2, y: y, width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { model.visible = true }
        tap = EventTap([.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] type, event in
            MainActor.assumeIsolated { self?.handle(type, event) ?? false }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = PickerPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: PickerView(model: model, picker: self))
        self.panel = panel
        return panel
    }

    private func resize() {
        guard let panel, let host = panel.contentView as? NSHostingView<PickerView> else { return }
        host.layoutSubtreeIfNeeded()
        var f = panel.frame
        let h = min(520, host.fittingSize.height)
        f.origin.y += f.height - h
        f.size.height = h
        panel.setFrame(f, display: true)
    }

    /// True = swallow the event.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type != .keyDown {
            if let panel, !NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) { close() }
            return false
        }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let mods = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate])
        let list = model.filtered
        switch code {
        case 53: close(); return true                                         // Esc
        case 36, 76: if model.selected < list.count { run(list[model.selected]) }; return true   // Return
        case 125: model.selected = min(model.selected + 1, max(0, list.count - 1)); return true  // ↓
        case 126: model.selected = max(model.selected - 1, 0); return true                       // ↑
        case 51:                                                                                  // ⌫
            if !model.query.isEmpty { model.query.removeLast(); model.selected = 0; resize() }
            return true
        default: break
        }
        if !mods.isEmpty { close(); return false }                           // a shortcut: let it through
        guard let chars = NSEvent(cgEvent: event)?.characters, let ch = chars.first else { return true }
        if model.query.isEmpty, let n = ch.wholeNumberValue, n >= 1, n <= min(9, list.count) {
            run(list[n - 1])
            return true
        }
        if ch.isLetter || ch.isNumber || ch == " " {
            model.query.append(ch)
            model.selected = 0
            resize()
        }
        return true
    }
}

private final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

struct PickerView: View {
    @ObservedObject var model: PickerModel
    let picker: ModePicker

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(.white.opacity(0.5))
                Text(model.query.isEmpty ? "Type to filter, or press a number" : model.query)
                    .foregroundColor(.white.opacity(model.query.isEmpty ? 0.4 : 1))
                Spacer()
                Text("esc").font(.system(size: 10, weight: .medium)).foregroundColor(.white.opacity(0.4))
            }
            .font(.system(size: 13))
            Text("“\(model.preview)”").font(.system(size: 11.5)).foregroundColor(.white.opacity(0.5)).lineLimit(1)
            Divider().overlay(Color.white.opacity(0.1))
            VStack(spacing: 2) {
                ForEach(Array(model.filtered.enumerated()), id: \.element.id) { i, mode in row(i, mode) }
                if model.filtered.isEmpty {
                    Text("No mode matches").foregroundColor(.white.opacity(0.4)).padding(8)
                }
            }
        }
        .padding(12)
        .frame(width: 440, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.06).opacity(0.96))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        )
        .foregroundColor(.white)
        .opacity(model.visible ? 1 : 0)
        .offset(y: model.visible ? 0 : -10)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ i: Int, _ mode: Mode) -> some View {
        HStack(spacing: 10) {
            Text(i < 9 && model.query.isEmpty ? "\(i + 1)" : "·")
                .font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(.white.opacity(0.5))
                .frame(width: 14)
            Image(systemName: mode.output == .replace ? "text.cursor" : mode.output == .show ? "text.bubble" : "arrowshape.turn.up.left.2")
                .font(.system(size: 11)).foregroundColor(Flicky.cyan).frame(width: 16)
            Text(mode.name).font(.system(size: 13.5, weight: i == model.selected ? .semibold : .regular))
            Spacer()
            if let hk = mode.hotkey {
                Text(hk.display).font(.system(size: 11, design: .rounded)).foregroundColor(.white.opacity(0.5))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.15)))
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(i == model.selected
            ? AnyShapeStyle(LinearGradient(colors: [Flicky.violet.opacity(0.55), Flicky.cyan.opacity(0.35)], startPoint: .leading, endPoint: .trailing))
            : AnyShapeStyle(Color.clear)))
        .contentShape(Rectangle())
        .onTapGesture { picker.run(mode) }
    }
}
