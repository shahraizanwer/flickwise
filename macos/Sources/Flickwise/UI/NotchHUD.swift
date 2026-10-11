// NotchHUD — the status indicator that grows out of the MacBook's notch (Dynamic Island style).
// A black island, the same black as the notch, springs out sideways ("wings") and down,
// then shrinks back into the notch. Left wing: Flicky, the mascot, reacting to the state.
// Right wing: live waveform + timer. Below the notch: a status line.
// Screens without a notch (external displays, older Macs) get the same island dropping
// from the top centre of the screen. Selected with `dictation.indicator: "notch"`; HUD.swift
// forwards to it.
// The panel is borderless, non-activating, above the menu bar, and ignores the mouse.
import AppKit
import SwiftUI

final class NotchModel: ObservableObject {
    enum Phase: Equatable {
        case hidden, listening
        case working(String)
        case done(String, detail: String?)
        case info(String, detail: String?)
        case error(String)
    }

    static let barCount = 9

    @Published var phase: Phase = .hidden
    @Published var expanded = false
    @Published var notch = CGSize(width: 180, height: 32)     // the physical notch (or a virtual one)
    @Published var hasNotch = true
    @Published var levels = [Float](repeating: 0, count: NotchModel.barCount)
    @Published var level: Float = 0
    @Published var startedAt = Date()

    func push(level value: Float) {
        level = value
        levels.removeFirst()
        levels.append(value)
    }
}

final class NotchHUD {
    static let shared = NotchHUD()

    let model = NotchModel()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var orderOutWork: DispatchWorkItem?
    private static let panelSize = NSSize(width: 760, height: 200)

    func listening() {
        model.levels = [Float](repeating: 0, count: NotchModel.barCount)
        model.level = 0
        model.startedAt = Date()
        show(.listening, autoHide: nil)
    }

    func level(_ value: Float) {
        if model.phase == .listening { model.push(level: value) }
    }

    func working(_ text: String) { show(.working(text), autoHide: nil) }
    func done(_ text: String, detail: String?) { show(.done(text, detail: detail), autoHide: 2.4) }
    func info(_ text: String, detail: String?) { show(.info(text, detail: detail), autoHide: 2.8) }
    func error(_ text: String) { show(.error(text), autoHide: 4.0) }

    /// Shrinks back into the notch, then removes the panel.
    func hide() {
        hideWork?.cancel()
        withAnimation(.spring(response: 0.38, dampingFraction: 0.92)) {
            model.expanded = false
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.model.expanded else { return }
            self.model.phase = .hidden
            self.panel?.orderOut(nil)
        }
        orderOutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    // ── private ──────────────────────────────────────────────────────────────

    private func show(_ phase: NotchModel.Phase, autoHide: TimeInterval?) {
        hideWork?.cancel()
        orderOutWork?.cancel()
        let panel = self.panel ?? makePanel()
        let wasHidden = !panel.isVisible || !model.expanded
        if wasHidden {
            place(panel)
            model.phase = phase
            model.expanded = false                       // start as the bare notch…
            panel.orderFrontRegardless()
            DispatchQueue.main.async {                   // …then spring out of it
                withAnimation(.spring(response: 0.46, dampingFraction: 0.74)) { self.model.expanded = true }
            }
        } else {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { model.phase = phase }
        }
        if let autoHide {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + autoHide, execute: work)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = TopPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)   // above the menu bar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: NotchView(model: model))
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        panel.contentView = host
        self.panel = panel
        return panel
    }

    /// Top centre of the screen you're working on; measures its notch.
    private func place(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        else { return }
        if let notch = Self.notchSize(of: screen) {
            model.notch = notch
            model.hasNotch = true
        } else {
            model.notch = CGSize(width: 150, height: 0)    // virtual notch: grow down from the top edge
            model.hasNotch = false
        }
        let f = screen.frame
        panel.setFrame(NSRect(x: f.midX - Self.panelSize.width / 2, y: f.maxY - Self.panelSize.height,
                              width: Self.panelSize.width, height: Self.panelSize.height), display: false)
    }

    /// The notch is the gap between the two "auxiliary" top areas, centred on the screen.
    static func notchSize(of screen: NSScreen) -> CGSize? {
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return nil }
        let width = screen.frame.width - left.width - right.width
        let height = screen.safeAreaInsets.top
        guard width > 40, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }
}

/// A panel macOS won't push below the menu bar.
private final class TopPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// ── the island ───────────────────────────────────────────────────────────────

private let wing: CGFloat = 108          // width of each side wing when expanded
private let earRadius: CGFloat = 8       // the concave flare where the island meets the menu bar

struct NotchView: View {
    @ObservedObject var model: NotchModel

    private var hasDetail: Bool {
        switch model.phase {
        case .working, .done, .info, .error: return true
        default: return false
        }
    }

    private var size: CGSize {
        let n = model.notch
        guard model.expanded else { return CGSize(width: n.width + 2 * earRadius, height: n.height) }
        let base = max(n.height, 32)
        switch model.phase {
        case .hidden: return CGSize(width: n.width + 2 * earRadius, height: n.height)
        case .listening: return CGSize(width: n.width + 2 * wing, height: base + 6)
        case .working: return CGSize(width: n.width + 2 * wing - 20, height: base + 32)
        default: return CGSize(width: n.width + 2 * wing + 40, height: base + 36)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(ear: earRadius, bottom: model.expanded ? 18 : 10)
                    .fill(Color.black)
                    .frame(width: size.width, height: size.height)
                    .shadow(color: .black.opacity(model.expanded ? 0.45 : 0), radius: 14, y: 6)
                    .overlay(alignment: .bottom) { glow }
                content
                    .frame(width: size.width - 2 * earRadius, height: size.height, alignment: .top)
                    .opacity(model.expanded ? 1 : 0)
                    .blur(radius: model.expanded ? 0 : 8)
                    .scaleEffect(model.expanded ? 1 : 0.85, anchor: .top)
                    .animation(.easeOut(duration: 0.22).delay(model.expanded ? 0.08 : 0), value: model.expanded)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// A soft violet → cyan line along the bottom edge that breathes with your voice.
    @ViewBuilder private var glow: some View {
        if model.phase == .listening && model.expanded {
            Capsule()
                .fill(LinearGradient(colors: [Flicky.violet, Flicky.cyan], startPoint: .leading, endPoint: .trailing))
                .frame(width: max(40, (size.width - 60) * CGFloat(0.35 + model.level * 0.65)), height: 2.5)
                .blur(radius: 1.5)
                .opacity(Double(0.35 + model.level * 0.65))
                .padding(.bottom, 2)
                .animation(.easeOut(duration: 0.12), value: model.level)
        }
    }

    @ViewBuilder private var content: some View {
        let rowHeight = max(model.notch.height, 32)
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                // left wing
                HStack {
                    Flicky(mood: mood, level: model.level)
                        .frame(width: 22, height: 22)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 14)
                .frame(width: wingWidth)
                Spacer(minLength: 0)                  // the camera
                // right wing
                HStack {
                    Spacer(minLength: 0)
                    rightWing
                }
                .padding(.trailing, 14)
                .frame(width: wingWidth)
            }
            .frame(height: rowHeight + (model.phase == .listening ? 6 : 0))
            if hasDetail { detail.padding(.horizontal, 18).padding(.bottom, 6) }
        }
    }

    private var wingWidth: CGFloat { wing - earRadius }

    private var mood: Flicky.Mood {
        switch model.phase {
        case .listening: return .listening
        case .working: return .thinking
        case .done: return .happy
        case .error: return .worried
        default: return .calm
        }
    }

    @ViewBuilder private var rightWing: some View {
        switch model.phase {
        case .listening:
            HStack(spacing: 7) {
                IslandWaveform(levels: model.levels)
                TimelineView(.periodic(from: model.startedAt, by: 1)) { ctx in
                    let s = max(0, Int(ctx.date.timeIntervalSince(model.startedAt)))
                    Text(String(format: "%d:%02d", s / 60, s % 60))
                        .font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
                        .foregroundColor(.white.opacity(0.6))
                }
            }
        case .working:
            BouncingDots()
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 15)).foregroundColor(Flicky.mint)
                .transition(.scale.combined(with: .opacity))
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 14)).foregroundColor(.orange)
        case .info:
            Image(systemName: "info.circle.fill").font(.system(size: 14)).foregroundColor(.white.opacity(0.7))
        case .hidden:
            EmptyView()
        }
    }

    @ViewBuilder private var detail: some View {
        Group {
            switch model.phase {
            case .working(let text):
                Text(text).foregroundColor(.white.opacity(0.75))
            case .done(let text, let more), .info(let text, let more):
                HStack(spacing: 6) {
                    Text(text).foregroundColor(.white)
                    if let more { Text(more).foregroundColor(.white.opacity(0.55)) }
                }
            case .error(let text):
                Text(text).foregroundColor(.orange.opacity(0.95))
            default:
                EmptyView()
            }
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity)
        .transition(.opacity)
    }
}

/// Notch-shaped island: concave "ears" where it meets the top edge, rounded bottom corners.
struct NotchShape: Shape {
    var ear: CGFloat
    var bottom: CGFloat

    var animatableData: CGFloat {
        get { bottom }
        set { bottom = newValue }
    }

    func path(in r: CGRect) -> Path {
        let b = min(bottom, (r.height - ear) / 2, (r.width - 2 * ear) / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + ear, y: r.minY + ear), control: CGPoint(x: r.minX + ear, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + ear, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + ear + b, y: r.maxY), control: CGPoint(x: r.minX + ear, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - ear - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - ear, y: r.maxY - b), control: CGPoint(x: r.maxX - ear, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - ear, y: r.minY + ear))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - ear, y: r.minY))
        p.closeSubpath()
        return p
    }
}

private struct IslandWaveform: View {
    let levels: [Float]
    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(LinearGradient(colors: [Flicky.cyan, Flicky.violet], startPoint: .top, endPoint: .bottom))
                    .frame(width: 3, height: 3 + CGFloat(levels[i]) * 15)
            }
        }
        .frame(height: 18)
        .animation(.easeOut(duration: 0.1), value: levels)
    }
}

private struct BouncingDots: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(i == 1 ? Flicky.cyan : Flicky.violet)
                        .frame(width: 5, height: 5)
                        .offset(y: -3 * max(0, sin(t * 6 - Double(i) * 0.7)))
                }
            }
        }
    }
}

// ── Flicky, the mascot ───────────────────────────────────────────────────────

/// A small glowing orb with eyes. It pulses with your voice, looks around while thinking,
/// smiles when it's done, and looks worried on errors. It blinks every few seconds.
struct Flicky: View {
    enum Mood { case calm, listening, thinking, happy, worried }

    static let violet = Color(red: 0.55, green: 0.36, blue: 0.98)
    static let cyan = Color(red: 0.13, green: 0.83, blue: 0.93)
    static let mint = Color(red: 0.30, green: 0.88, blue: 0.55)

    var mood: Mood
    var level: Float

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let d = min(geo.size.width, geo.size.height)
                let pulse = mood == .listening ? 1 + CGFloat(level) * 0.22 : 1 + 0.04 * CGFloat(sin(t * 2))
                ZStack {
                    // glow
                    Circle()
                        .fill(RadialGradient(colors: [Self.violet.opacity(0.7), .clear], center: .center,
                                             startRadius: 0, endRadius: d * 0.9))
                        .frame(width: d * 1.8, height: d * 1.8)
                        .opacity(mood == .listening ? Double(0.35 + level * 0.65) : 0.35)
                    // body
                    Circle()
                        .fill(AngularGradient(colors: [Self.violet, Self.cyan, Self.violet],
                                              center: .center, angle: .degrees(mood == .thinking ? t * 240 : t * 30)))
                        .overlay(Circle().fill(
                            RadialGradient(colors: [.white.opacity(0.35), .clear], center: UnitPoint(x: 0.35, y: 0.3),
                                           startRadius: 0, endRadius: d * 0.5)))
                        .frame(width: d, height: d)
                        .scaleEffect(pulse)
                    eyes(d: d, t: t)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    @ViewBuilder private func eyes(d: CGFloat, t: Double) -> some View {
        let blink = mood != .happy && (t.truncatingRemainder(dividingBy: 3.7)) < 0.13
        let look: CGFloat = mood == .thinking ? CGFloat(sin(t * 3)) * d * 0.09 : 0
        let gap = d * 0.2
        HStack(spacing: gap) {
            ForEach(0..<2) { _ in
                switch mood {
                case .happy:
                    HappyEye().stroke(Color.white, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                        .frame(width: d * 0.2, height: d * 0.12)
                case .worried:
                    Capsule().fill(Color.white).frame(width: d * 0.16, height: d * 0.16)
                default:
                    Capsule().fill(Color.white)
                        .frame(width: d * 0.14, height: blink ? d * 0.03 : d * 0.26)
                }
            }
        }
        .offset(x: look, y: mood == .worried ? d * 0.04 : -d * 0.02)
    }
}

/// "^" shaped eye for the happy face.
private struct HappyEye: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: r.midX, y: r.minY - r.height))
        return p
    }
}
