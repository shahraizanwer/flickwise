// HUD — the status indicator. With `dictation.indicator: "notch"` (default) every call is
// forwarded to NotchHUD (an island growing out of the notch); with "pill" it's the
// floating pill at the bottom of the screen, below.
// A borderless, non-activating panel that ignores the mouse, so the app you're
// typing in keeps focus. Shows: Listening (live waveform + timer), Transcribing,
// Done (with a preview), Copied, and errors.
import AppKit
import SwiftUI

final class HUDModel: ObservableObject {
    enum Phase: Equatable {
        case hidden
        case listening
        case working(String)
        case done(String, detail: String?)
        case info(String, detail: String?)
        case error(String)
    }

    static let barCount = 26

    @Published var phase: Phase = .hidden
    @Published var levels = [Float](repeating: 0, count: HUDModel.barCount)
    @Published var startedAt = Date()
    @Published var hint: String?

    func push(level: Float) {
        levels.removeFirst()
        levels.append(level)
    }
}

final class HUD {
    static let shared = HUD()

    let model = HUDModel()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private static let size = NSSize(width: 520, height: 90)

    private var notch: NotchHUD? {
        SettingsStore.shared.settings.dictation.indicator == .notch ? NotchHUD.shared : nil
    }

    func listening(hint: String?) {
        if let notch { hidePill(); notch.listening(); return }
        model.levels = [Float](repeating: 0, count: HUDModel.barCount)
        model.startedAt = Date()
        model.hint = hint
        show(.listening, autoHide: nil)
    }

    func level(_ value: Float) {
        if let notch { notch.level(value); return }
        if model.phase == .listening { model.push(level: value) }
    }

    func working(_ text: String) {
        if let notch { notch.working(text); return }
        show(.working(text), autoHide: nil)
    }
    func done(_ text: String, detail: String? = nil) {
        if let notch { notch.done(text, detail: detail); return }
        show(.done(text, detail: detail), autoHide: 2.2)
    }
    func info(_ text: String, detail: String? = nil) {
        if let notch { notch.info(text, detail: detail); return }
        show(.info(text, detail: detail), autoHide: 2.6)
    }
    func error(_ text: String) {
        if let notch { notch.error(text); return }
        show(.error(text), autoHide: 4.0)
    }

    func hide() {
        if let notch { notch.hide(); return }
        hidePill()
    }

    private func hidePill() {
        guard model.phase != .hidden else { return }
        hideWork?.cancel()
        withAnimation(.easeIn(duration: 0.18)) { model.phase = .hidden }
        let work = DispatchWorkItem { [weak self] in
            if self?.model.phase == .hidden { self?.panel?.orderOut(nil) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // ── private ──────────────────────────────────────────────────────────────

    private func show(_ phase: HUDModel.Phase, autoHide: TimeInterval?) {
        hideWork?.cancel()
        let panel = self.panel ?? makePanel()
        position(panel)
        panel.orderFrontRegardless()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { model.phase = phase }
        if let autoHide {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + autoHide, execute: work)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: HUDView(model: model))
        host.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = host
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2, y: frame.minY + 14))
    }
}

// ── view ─────────────────────────────────────────────────────────────────────

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if model.phase != .hidden {
                pill
                    .transition(.asymmetric(insertion: .scale(scale: 0.85).combined(with: .opacity)
                                                .combined(with: .offset(y: 10)),
                                            removal: .opacity.combined(with: .scale(scale: 0.95))))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 6)
    }

    private var pill: some View {
        HStack(spacing: 10) {
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule().fill(Color(white: 0.08).opacity(0.92))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        )
        .foregroundColor(.white)
        .font(.system(size: 13, weight: .medium))
        .fixedSize()
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .hidden:
            EmptyView()
        case .listening:
            PulsingDot()
            Text("Listening")
            Waveform(levels: model.levels)
            TimelineView(.periodic(from: model.startedAt, by: 1)) { ctx in
                Text(elapsed(ctx.date)).monospacedDigit().foregroundColor(.white.opacity(0.55))
            }
            if let hint = model.hint {
                Text(hint).font(.system(size: 11)).foregroundColor(.white.opacity(0.4))
            }
        case .working(let text):
            ProgressView().controlSize(.small).colorScheme(.dark)
            Text(text)
        case .done(let text, let detail):
            Image(systemName: "checkmark.circle.fill").foregroundColor(Color(red: 0.3, green: 0.85, blue: 0.5))
            Text(text)
            if let detail { Text(detail).foregroundColor(.white.opacity(0.55)).lineLimit(1).frame(maxWidth: 300) }
        case .info(let text, let detail):
            Image(systemName: "info.circle.fill").foregroundColor(.white.opacity(0.7))
            Text(text)
            if let detail { Text(detail).foregroundColor(.white.opacity(0.55)).lineLimit(1).frame(maxWidth: 300) }
        case .error(let text):
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            Text(text).lineLimit(2).frame(maxWidth: 400)
        }
    }

    private func elapsed(_ now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(model.startedAt)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct PulsingDot: View {
    @State private var on = false
    var body: some View {
        Circle()
            .fill(Color(red: 1, green: 0.27, blue: 0.27))
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(Color.red.opacity(0.5), lineWidth: 2).scaleEffect(on ? 2.0 : 1).opacity(on ? 0 : 1))
            .onAppear { withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { on = true } }
    }
}

private struct Waveform: View {
    let levels: [Float]
    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(0.35 + Double(levels[i]) * 0.65))
                    .frame(width: 3, height: 3 + CGFloat(levels[i]) * 19)
            }
        }
        .frame(height: 22)
        .animation(.linear(duration: 0.08), value: levels)
    }
}
