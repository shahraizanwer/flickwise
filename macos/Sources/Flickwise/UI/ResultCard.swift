// ResultCard — the card that appears after a fix. Port of lib/diff_bubble.lua. Three kinds:
//   diff     "what changed" word diff (deleted = red strikethrough, inserted = green) with Undo
//   text     an answer (show modes); lines like "Meaning: …" become labelled rows; Copy
//   replies  Reply Helper: the meaning + up to 9 replies; 1–n or a click inserts one; Copy per reply
// It drops in under the notch island (or above the bottom pill), auto-dismisses after the
// configured time with a draining bar, and pauses while the pointer is over it.
// Keys while visible (a session EventTap):
//   diff     undo hotkey → Undo; any other key → dismiss and pass the key through
//   text     any key → dismiss and pass through
//   replies  1–n (no modifiers) → insert while "armed"; any other key disarms and passes through
//            (so typed digits are never swallowed); Esc closes. Outside clicks don't close it.
// Clicks outside a diff/text card dismiss it. The tap is stopped before synthetic keys are sent.
import AppKit
import SwiftUI

final class CardModel: ObservableObject {
    enum Kind: Equatable {
        case diff(segments: [WordDiff.Segment], changes: Int)
        case text(String)
        case replies(ReplyData)
    }

    @Published var kind: Kind = .text("")
    @Published var mode = ""
    @Published var remaining: Double = 1      // 0…1 of the countdown
    @Published var paused = false
    @Published var copiedIndex: Int?
    @Published var visible = false

    var isReplies: Bool { if case .replies = kind { return true } else { return false } }
}

@MainActor
final class ResultCard {
    static let shared = ResultCard()

    let model = CardModel()
    private var panel: NSPanel?
    private var tap: EventTap?
    private var clock: Timer?
    private var total: Double = 6
    private var left: Double = 6
    private var onUndo: (() -> Void)?
    private var target: NSRunningApplication?
    private var armed = true

    private static let width: CGFloat = 560

    func showDiff(original: String, result: String, mode: String, target: NSRunningApplication?, undo: @escaping () -> Void) {
        let s = SettingsStore.shared.settings.diffCard
        let (segs, changes) = WordDiff.diff(original, result)
        present(.diff(segments: WordDiff.collapsed(segs, context: s.contextWords), changes: changes),
                mode: mode, seconds: Double(s.durationSeconds), target: target)
        onUndo = undo
    }

    func showText(_ text: String, mode: String) {
        present(.text(text), mode: mode, seconds: Double(SettingsStore.shared.settings.resultCard.durationSeconds), target: nil)
    }

    func showReplies(_ data: ReplyData, mode: String, target: NSRunningApplication?) {
        armed = true
        present(.replies(data), mode: mode, seconds: Double(SettingsStore.shared.settings.replyCard.durationSeconds),
                target: target)
    }

    func dismiss() {
        tap?.stop(); tap = nil
        clock?.invalidate(); clock = nil
        onUndo = nil
        guard model.visible else { return }
        withAnimation(.easeIn(duration: 0.15)) { model.visible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            if self?.model.visible == false { self?.panel?.orderOut(nil) }
        }
    }

    // ── actions (from the view or keys) ──────────────────────────────────────

    func undo() {
        let action = onUndo
        dismiss()                                   // stops the tap before synthetic keys
        target?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { action?() }
    }

    func copy(_ text: String, index: Int = 0) {
        TextInserter.copyToClipboard(text)
        model.copiedIndex = index
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.model.copiedIndex = nil }
    }

    func choose(_ reply: ReplyData.Reply) {
        let target = self.target
        dismiss()
        FixController.shared.insert(reply.text, into: target)
    }

    // ── private ──────────────────────────────────────────────────────────────

    private func present(_ kind: CardModel.Kind, mode: String, seconds: Double, target: NSRunningApplication?) {
        dismiss()
        self.target = target
        model.kind = kind
        model.mode = mode
        model.remaining = 1
        model.paused = false
        model.copiedIndex = nil
        total = max(1, seconds)
        left = total

        let panel = self.panel ?? makePanel()
        let host = panel.contentView as! NSHostingView<CardView>
        host.layoutSubtreeIfNeeded()
        let size = NSSize(width: Self.width, height: min(460, host.fittingSize.height))
        place(panel, size: size)
        panel.orderFrontRegardless()
        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { model.visible = true }
        startClock()
        startTap()
    }

    private func makePanel() -> NSPanel {
        let panel = CardPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: CardView(model: model, card: self))
        self.panel = panel
        return panel
    }

    /// Under the notch island (default) or above the bottom pill.
    private func place(_ panel: NSPanel, size: NSSize) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let f = screen.frame, v = screen.visibleFrame
        let y: CGFloat
        if SettingsStore.shared.settings.dictation.indicator == .notch {
            let top = NotchHUD.notchSize(of: screen)?.height ?? (f.maxY - v.maxY)
            y = f.maxY - top - 82 - size.height                 // below the island's status row
        } else {
            y = v.minY + 64
        }
        panel.setFrame(NSRect(x: f.midX - size.width / 2, y: y, width: size.width, height: size.height), display: true)
    }

    /// Lua owned the clock too: the bar shows the remaining time and pauses while hovered.
    private func startClock() {
        clock = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                let hovering = NSMouseInRect(NSEvent.mouseLocation, panel.frame, false)
                if self.model.paused != hovering { self.model.paused = hovering }
                guard !hovering else { return }
                self.left -= 0.1
                self.model.remaining = max(0, self.left / self.total)
                if self.left <= 0 { self.dismiss() }
            }
        }
    }

    private func startTap() {
        tap = EventTap([.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] type, event in
            MainActor.assumeIsolated { self?.handle(type, event) ?? false }
        }
    }

    /// Returns true to swallow the event.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .leftMouseDown || type == .rightMouseDown {
            // Outside clicks close diff/answer cards; the reply card stays so you can click into your reply box.
            let outside = panel.map { !NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? false
            if outside, !model.isReplies { dismiss() }
            return false
        }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let mods = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        switch model.kind {
        case .diff:
            if onUndo != nil, SettingsStore.shared.settings.diffCard.undoHotkey.matches(event),
               NSWorkspace.shared.frontmostApplication == target {
                DispatchQueue.main.async { self.undo() }
                return true
            }
            dismiss()
            return false
        case .text:
            dismiss()
            return false
        case .replies(let data):
            if code == 53 { dismiss(); return false }                       // Esc
            if armed, mods.isEmpty, let n = Self.digit(event), n >= 1, n <= data.replies.count {
                let reply = data.replies[n - 1]
                DispatchQueue.main.async { self.choose(reply) }
                return true
            }
            armed = false                                                   // typing: never eat digits now
            return false
        }
    }

    /// The digit typed (top row or keypad, any layout), from the event's characters.
    static func digit(_ event: CGEvent) -> Int? {
        guard let ch = NSEvent(cgEvent: event)?.characters?.first, ch.isASCII else { return nil }
        return ch.wholeNumberValue
    }
}

/// Clicks reach the card without activating Flickwise.
private final class CardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

// ── view ─────────────────────────────────────────────────────────────────────

struct CardView: View {
    @ObservedObject var model: CardModel
    let card: ResultCard

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 16)
        .frame(width: 560, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(white: 0.06).opacity(0.96))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        )
        .overlay(alignment: .bottom) { countdown }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .foregroundColor(.white)
        .opacity(model.visible ? 1 : 0)
        .offset(y: model.visible ? 0 : -14)
        .scaleEffect(model.visible ? 1 : 0.97, anchor: .top)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Flicky(mood: .happy, level: 0).frame(width: 16, height: 16)
            Text(model.mode).font(.system(size: 13, weight: .semibold, design: .rounded))
            Text(subtitle).font(.system(size: 12)).foregroundColor(.white.opacity(0.5))
            Spacer()
            headerButtons
        }
    }

    private var subtitle: String {
        if model.paused { return "Paused while you read" }
        switch model.kind {
        case .diff(_, let n): return n == 1 ? "1 change" : "\(n) changes"
        case .text: return "your text wasn't changed"
        case .replies(let d): return "press 1–\(d.replies.count) to insert"
        }
    }

    @ViewBuilder private var headerButtons: some View {
        switch model.kind {
        case .diff:
            Button { card.undo() } label: {
                Label("Undo \(SettingsStore.shared.settings.diffCard.undoHotkey.display)", systemImage: "arrow.uturn.backward")
            }.buttonStyle(CardButton())
        case .text(let text):
            Button(model.copiedIndex == 0 ? "Copied" : "Copy") { card.copy(text) }.buttonStyle(CardButton())
        case .replies:
            EmptyView()
        }
        Button { card.dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(CardButton())
    }

    @ViewBuilder private var content: some View {
        switch model.kind {
        case .diff(let segs, _):
            ScrollView { diffText(segs).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 220).fixedSize(horizontal: false, vertical: true)
        case .text(let text):
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(Self.rows(text).enumerated()), id: \.offset) { _, row in
                        VStack(alignment: .leading, spacing: 2) {
                            if let label = row.label {
                                Text(label.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundColor(Flicky.cyan)
                            }
                            Text(row.text).font(.system(size: 13.5)).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240).fixedSize(horizontal: false, vertical: true)
        case .replies(let data):
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !data.meaning.isEmpty {
                        Text(data.meaning).font(.system(size: 13)).foregroundColor(.white.opacity(0.75))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(data.replies) { r in replyRow(r) }
                }
            }
            .frame(maxHeight: 330).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func replyRow(_ r: ReplyData.Reply) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(r.id + 1)").font(.system(size: 12, weight: .bold, design: .rounded))
                .frame(width: 20, height: 20).background(Circle().fill(Flicky.violet.opacity(0.8)))
            VStack(alignment: .leading, spacing: 3) {
                Text(r.label).font(.system(size: 11, weight: .semibold)).foregroundColor(Flicky.cyan)
                Text(r.text).font(.system(size: 13.5)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button(model.copiedIndex == r.id + 1 ? "Copied" : "Copy") { card.copy(r.text, index: r.id + 1) }
                .buttonStyle(CardButton())
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
        .contentShape(Rectangle())
        .onTapGesture { card.choose(r) }
    }

    private func diffText(_ segs: [WordDiff.Segment]) -> Text {
        DiffText.make(segs, plain: .white.opacity(0.8)).font(.system(size: 14))
    }

    private var countdown: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(model.paused ? Color.white.opacity(0.3)
                      : Color.clear)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(model.paused ? AnyShapeStyle(Color.white.opacity(0.35))
                              : AnyShapeStyle(LinearGradient(colors: [Flicky.violet, Flicky.cyan], startPoint: .leading, endPoint: .trailing)))
                        .frame(width: geo.size.width * model.remaining)
                        .animation(.linear(duration: 0.1), value: model.remaining)
                }
        }
        .frame(height: 3)
        .opacity(model.paused ? 0.6 : 1)
    }

    /// "Label: text" lines become labelled rows; other lines continue the current row.
    static func rows(_ text: String) -> [(label: String?, text: String)] {
        var rows: [(String?, String)] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let colon = trimmed.firstIndex(of: ":"), trimmed.distance(from: trimmed.startIndex, to: colon) <= 24,
               trimmed[..<colon].allSatisfy({ $0.isLetter || $0 == " " || $0 == "/" }), !trimmed[..<colon].isEmpty {
                rows.append((String(trimmed[..<colon]), trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
            } else if !trimmed.isEmpty {
                if rows.isEmpty { rows.append((nil, trimmed)) } else { rows[rows.count - 1].1 += "\n" + trimmed }
            }
        }
        return rows.map { (label: $0.0, text: $0.1) }
    }
}

private struct CardButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.25 : 0.12)))
            .foregroundColor(.white)
    }
}

/// A word diff as one Text: deletions red and struck through, insertions green and bold.
enum DiffText {
    static func make(_ segs: [WordDiff.Segment], plain: Color = .primary) -> Text {
        var out = Text("")
        for s in segs {
            let t = Text(s.text)
            switch s.op {
            case .eq: out = out + t.foregroundColor(plain)
            case .del: out = out + t.foregroundColor(Color(red: 0.95, green: 0.35, blue: 0.35)).strikethrough()
            case .ins: out = out + t.foregroundColor(Color(red: 0.2, green: 0.72, blue: 0.42)).bold()
            }
        }
        return out
    }
}
