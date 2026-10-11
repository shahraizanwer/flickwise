// RadialMenu — hold a right-hand modifier (Right ⌥ by default), flick toward a mode, release.
// Port of lib/radial_menu.lua.
//   pending (hold_ms) → open: the ring springs out at the pointer; moving the pointer outside a
//   28 pt dead zone highlights the slot in that direction (slot 1 at the top, then clockwise).
//   release → apply the highlighted slot (in the dead zone: cancel) · 1–8 apply · left click applies ·
//   right click / Esc cancel · any other key cancels and passes through.
// A tap, or the modifier used in a shortcut (another key/modifier while pending), does nothing.
// The capture happens after the trigger is released (FixController.run).
import AppKit
import SwiftUI

final class RadialModel: ObservableObject {
    @Published var modes: [Mode] = []
    @Published var highlighted: Int?
    @Published var open = false
    @Published var applied: Int?
}

@MainActor
final class RadialMenu {
    static let shared = RadialMenu()

    let model = RadialModel()
    private var monitor: HotkeyMonitor?
    private var sessionTap: EventTap?
    private var panel: NSPanel?
    private var holdWork: DispatchWorkItem?
    private var origin = NSPoint.zero
    private var state: State = .idle

    private enum State { case idle, pending, open }
    private static let size = NSSize(width: 560, height: 360)
    private static let deadZone: CGFloat = 28

    var isActive: Bool { state != .idle }

    /// (Re)binds the trigger from settings. Call after settings change.
    func apply() {
        let s = SettingsStore.shared.settings
        let dictationTrigger = s.dictation.enabled ? s.dictation.trigger : nil
        guard s.radialMenu.enabled, s.radialMenu.trigger != dictationTrigger else {
            if s.radialMenu.enabled { Log.info("Radial menu off: its trigger is also the dictation key") }
            stop()
            return
        }
        if monitor?.trigger != s.radialMenu.trigger { stop() }
        if monitor == nil {
            let m = HotkeyMonitor(trigger: s.radialMenu.trigger)
            m.escapeIsOurs = { [weak self] in
                MainActor.assumeIsolated { self?.state == .pending }
            }
            m.onEvent = { [weak self] e in DispatchQueue.main.async { self?.handle(e) } }
            if m.start() { monitor = m; Log.info("Radial menu ready (hold \(s.radialMenu.trigger.short))") }
        }
    }

    func stop() {
        cancel()
        monitor?.stop()
        monitor = nil
    }

    // ── trigger ──────────────────────────────────────────────────────────────

    private func handle(_ e: HotkeyMonitor.Event) {
        switch (e, state) {
        case (.pressed, .idle):
            guard !FixController.shared.inFlight, AppDelegate.shared?.dictation.state == .idle,
                  !ModePicker.shared.isOpen else { return }
            state = .pending
            origin = NSEvent.mouseLocation
            monitor?.startKeyTap()
            let work = DispatchWorkItem { [weak self] in self?.openRing() }
            holdWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(SettingsStore.shared.settings.radialMenu.holdMs),
                                          execute: work)
        case (.chord, .pending), (.released, .pending), (.escape, .pending):
            cancel()
        case (.released, .open):
            applyHighlighted()
        default:
            break
        }
    }

    private func openRing() {
        guard state == .pending else { return }
        let modes = slots()
        guard !modes.isEmpty else { cancel(); return }
        monitor?.stopKeyTap()
        state = .open
        ResultCard.shared.dismiss()
        model.modes = modes
        model.highlighted = nil
        model.applied = nil
        origin = NSEvent.mouseLocation
        let panel = self.panel ?? makePanel()
        place(panel)
        panel.orderFrontRegardless()
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.72)) { self.model.open = true }
        }
        sessionTap = EventTap([.keyDown, .mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown]) { [weak self] type, event in
            MainActor.assumeIsolated { self?.session(type, event) ?? false }
        }
    }

    /// Slot order: settings.radialMenu.modes (ids), else the first 8 enabled modes.
    private func slots() -> [Mode] {
        let all = ModeStore.shared.enabledModes
        let ids = SettingsStore.shared.settings.radialMenu.modes
        let chosen = ids.compactMap { id in all.first { $0.id == id } }
        return Array((chosen.isEmpty ? all : chosen).prefix(8))
    }

    private func session(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .mouseMoved, .leftMouseDragged:
            updateHighlight()
            return false
        case .leftMouseDown:
            applyHighlighted()
            return true
        case .rightMouseDown:
            cancel()
            return true
        case .keyDown:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if let n = ResultCard.digit(event), n >= 1, n <= model.modes.count {
                model.highlighted = n - 1
                applyHighlighted()
                return true
            }
            cancel()
            return code == 53                         // swallow Esc, pass everything else through
        default:
            return false
        }
    }

    private func updateHighlight() {
        let p = NSEvent.mouseLocation
        let dx = p.x - origin.x, dy = p.y - origin.y
        guard hypot(dx, dy) > Self.deadZone, !model.modes.isEmpty else {
            if model.highlighted != nil { model.highlighted = nil }
            return
        }
        var angle = atan2(dx, dy) * 180 / .pi                        // 0 = up, clockwise
        if angle < 0 { angle += 360 }
        let step = 360 / Double(model.modes.count)
        let slot = Int((angle / step).rounded()) % model.modes.count
        if model.highlighted != slot { model.highlighted = slot }
    }

    private func applyHighlighted() {
        guard state == .open, let i = model.highlighted, i < model.modes.count else { cancel(); return }
        let mode = model.modes[i]
        model.applied = i
        sessionTap?.stop(); sessionTap = nil
        state = .idle
        withAnimation(.easeIn(duration: 0.18).delay(0.06)) { model.open = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { [weak self] in self?.panel?.orderOut(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { FixController.shared.run(mode) }
    }

    private func cancel() {
        holdWork?.cancel(); holdWork = nil
        monitor?.stopKeyTap()
        sessionTap?.stop(); sessionTap = nil
        let wasOpen = state == .open
        state = .idle
        guard wasOpen else { return }
        withAnimation(.easeIn(duration: 0.15)) { model.open = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.panel?.orderOut(nil) }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: RadialView(model: model))
        self.panel = panel
        return panel
    }

    /// Centred on the pointer, kept on screen.
    private func place(_ panel: NSPanel) {
        let s = Self.size
        var frame = NSRect(x: origin.x - s.width / 2, y: origin.y - s.height / 2, width: s.width, height: s.height)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(origin, $0.frame, false) }) {
            let v = screen.visibleFrame
            frame.origin.x = min(max(frame.minX, v.minX), v.maxX - s.width)
            frame.origin.y = min(max(frame.minY, v.minY), v.maxY - s.height)
        }
        panel.setFrame(frame, display: true)
    }
}

// ── the ring ─────────────────────────────────────────────────────────────────

private struct RadialView: View {
    @ObservedObject var model: RadialModel
    private let rx: CGFloat = 175, ry: CGFloat = 175 * 0.78           // slightly flattened ring

    var body: some View {
        ZStack {
            hub
            ForEach(Array(model.modes.enumerated()), id: \.element.id) { i, mode in
                pill(i, mode)
                    .offset(model.open ? offset(i) : .zero)
                    .scaleEffect(model.open ? (model.applied == i ? 1.12 : 1) : 0.3)
                    .opacity(model.open ? (model.applied == nil || model.applied == i ? 1 : 0.3) : 0)
                    .animation(.spring(response: 0.34, dampingFraction: 0.7).delay(model.open ? Double(i) * 0.03 : 0),
                               value: model.open)
                    .animation(.easeOut(duration: 0.12), value: model.highlighted)
            }
        }
        .frame(width: 560, height: 360)
    }

    private func offset(_ i: Int) -> CGSize {
        let n = max(1, model.modes.count)
        let a = Double(i) / Double(n) * 2 * .pi                      // 0 = top, clockwise
        return CGSize(width: rx * CGFloat(sin(a)), height: -ry * CGFloat(cos(a)))
    }

    private var hub: some View {
        ZStack {
            Circle().fill(Color(white: 0.06).opacity(0.92)).frame(width: 56, height: 56)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.12)))
            if let h = model.highlighted {
                Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold)).foregroundColor(Flicky.cyan)
                    .rotationEffect(.degrees(Double(h) / Double(max(1, model.modes.count)) * 360))
            } else {
                Flicky(mood: .calm, level: 0).frame(width: 24, height: 24)
            }
        }
        .scaleEffect(model.open ? 1 : 0.4)
        .opacity(model.open ? 1 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: model.open)
    }

    private func pill(_ i: Int, _ mode: Mode) -> some View {
        let on = model.highlighted == i
        return HStack(spacing: 6) {
            Text("\(i + 1)").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(.white.opacity(0.6))
            Text(mode.name).font(.system(size: 13, weight: on ? .semibold : .medium)).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(
            Capsule().fill(on
                ? AnyShapeStyle(LinearGradient(colors: [Flicky.violet, Flicky.cyan], startPoint: .leading, endPoint: .trailing))
                : AnyShapeStyle(Color(white: 0.08).opacity(0.94)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(on ? 0.3 : 0.12)))
                .shadow(color: (on ? Flicky.violet : .black).opacity(0.45), radius: on ? 10 : 6, y: 3)
        )
        .foregroundColor(.white)
        .scaleEffect(on ? 1.08 : 1)
        .fixedSize()
    }
}
