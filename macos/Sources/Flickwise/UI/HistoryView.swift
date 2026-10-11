// HistoryView — "Voice History": everything you've dictated, newest first.
// Search (full text, as you type), stats, and per-entry Copy / Original / Retry / Delete.
import AppKit
import Combine
import SwiftUI

final class HistoryViewModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var sections: [(day: Date, records: [DictationRecord])] = []
    @Published private(set) var stats = HistoryStats()
    @Published private(set) var count = 0
    @Published var retrying: Set<Int64> = []

    private let store: HistoryStore
    private var bag = Set<AnyCancellable>()

    init(store: HistoryStore = .shared) {
        self.store = store
        $query.removeDuplicates().debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }.store(in: &bag)
        store.$revision.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }.store(in: &bag)
        reload()
    }

    func reload() {
        let q = query.trimmingCharacters(in: .whitespaces)
        let records = q.isEmpty ? store.recent(limit: 1000) : store.search(q, limit: 1000)
        let cal = Calendar.current
        var grouped: [(Date, [DictationRecord])] = []
        for r in records {
            let day = cal.startOfDay(for: r.createdAt)
            if grouped.last?.0 == day { grouped[grouped.count - 1].1.append(r) } else { grouped.append((day, [r])) }
        }
        sections = grouped.map { (day: $0.0, records: $0.1) }
        count = records.count
        stats = store.stats()
    }

    func delete(_ r: DictationRecord) { store.delete(id: r.id) }

    func retry(_ r: DictationRecord) {
        guard let controller = AppDelegate.shared?.dictation else { return }
        retrying.insert(r.id)
        Task { @MainActor in
            _ = await controller.retry(r)
            retrying.remove(r.id)
        }
    }

    func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Flickwise Voice History.md"
        panel.allowedContentTypes = [.init(filenameExtension: "md")!]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        var out = "# Flickwise Voice History\n\n"
        for r in store.recent(limit: 1_000_000) where r.status != .failed {
            out += "## \(df.string(from: r.createdAt))\(r.appName.map { " · \($0)" } ?? "")\n\n\(r.text)\n\n"
        }
        try? out.write(to: url, atomically: true, encoding: .utf8)
    }
}

struct HistoryView: View {
    @StateObject private var model = HistoryViewModel()
    @ObservedObject private var settings = SettingsStore.shared
    @AppStorage("hideNotchTip") private var hideNotchTip = false
    @State private var iconHidden = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if iconHidden && !hideNotchTip { notchTip }
            Divider()
            if model.sections.isEmpty {
                empty
            } else {
                list
            }
        }
        .frame(minWidth: 560, minHeight: 440)
        .onAppear {
            // At launch macOS hasn't placed the menu bar icon yet: check once it has.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                iconHidden = AppDelegate.shared?.menuBarIconHidden ?? false
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                StatTile(value: model.stats.todayWords.formatted(), label: "words today")
                StatTile(value: model.stats.weekWords.formatted(), label: "this week")
                StatTile(value: model.stats.totalWords.formatted(), label: "all time")
                StatTile(value: Self.duration(minutes: model.stats.minutesSaved), label: "saved vs typing")
                StatTile(value: "\(model.stats.streakDays)", label: model.stats.streakDays == 1 ? "day streak" : "day streak")
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search everything you've said", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundColor(.secondary)
                }
                Menu {
                    Button("Export as Markdown…") { model.export() }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        }
        .padding(.horizontal, 20).padding(.top, 34).padding(.bottom, 14)
    }

    /// The menu bar is full and macOS hid our icon behind the camera notch.
    private var notchTip: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "menubar.rectangle").foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("The Flickwise menu bar icon is hidden behind the camera notch").fontWeight(.semibold)
                Text("Your menu bar is full. Dictation still works (hold \(settings.settings.dictation.trigger.short)). "
                     + "To reach Flickwise, open it from Spotlight or Applications, or make room by ⌘-dragging other icons out of the menu bar.")
                    .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Settings…") { AppDelegate.shared?.showSettings() }
                    Button("Don't show again") { hideNotchTip = true }
                }.controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.1)))
        .padding(.horizontal, 20).padding(.bottom, 12)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6, pinnedViews: [.sectionHeaders]) {
                ForEach(model.sections, id: \.day) { section in
                    Section {
                        ForEach(section.records) { r in
                            HistoryRow(record: r, retrying: model.retrying.contains(r.id),
                                       onDelete: { model.delete(r) }, onRetry: { model.retry(r) })
                        }
                    } header: {
                        Text(Self.dayTitle(section.day))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                            .background(Color(nsColor: .windowBackgroundColor).opacity(0.95))
                    }
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 20)
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: model.query.isEmpty ? "waveform" : "magnifyingglass")
                .font(.system(size: 36, weight: .light)).foregroundColor(.secondary)
            Text(model.query.isEmpty ? "Nothing here yet" : "No matches")
                .font(.title3.weight(.semibold))
            Text(model.query.isEmpty
                 ? "Hold \(settings.settings.dictation.trigger.short), speak, and let go. Everything you say is kept here, on this Mac."
                 : "Try fewer or different words.")
                .foregroundColor(.secondary).multilineTextAlignment(.center).frame(maxWidth: 340)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    static func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = cal.isDate(day, equalTo: Date(), toGranularity: .year) ? "EEEE, d MMMM" : "d MMMM yyyy"
        return f.string(from: day)
    }

    static func duration(minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : String(format: "%.1f h", Double(minutes) / 60)
    }
}

private struct StatTile: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 11)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

private struct HistoryRow: View {
    let record: DictationRecord
    let retrying: Bool
    let onDelete: () -> Void
    let onRetry: () -> Void

    @State private var hover = false
    @State private var showOriginal = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.createdAt, style: .time).font(.system(size: 12, weight: .medium)).monospacedDigit()
                if let app = record.appName {
                    Text(app).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                }
            }
            .frame(width: 76, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                if record.status == .failed {
                    Label(record.error ?? "Failed", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundColor(.orange)
                    Text("Recording saved (\(Int(record.duration.rounded())) s). Retry when you're back online.")
                        .font(.system(size: 13)).foregroundColor(.secondary)
                } else {
                    Text(record.text).font(.system(size: 13.5)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if showOriginal && !record.rawText.isEmpty && record.rawText != record.text {
                    Text(record.rawText).font(.system(size: 12)).foregroundColor(.secondary).textSelection(.enabled)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                }
                HStack(spacing: 8) {
                    Tag(text: record.style.title)
                    if let engine = Self.engineLabel(record.engine) { Tag(text: engine) }
                    Tag(text: "\(record.wordCount) words · \(Int(record.duration.rounded())) s")
                    Spacer()
                    actions.opacity(hover || retrying ? 1 : 0)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hover ? 0.06 : 0.03)))
        .onHover { hover = $0 }
    }

    /// "whisper:large-v3-turbo-q5_0" → "On-device · Large v3 Turbo (compressed)"; "gemini:…" → "Gemini".
    static func engineLabel(_ engine: String?) -> String? {
        guard let engine else { return nil }
        if engine.hasPrefix("gemini") { return "Gemini" }
        let id = engine.replacingOccurrences(of: "whisper:", with: "")
        return "On-device · " + (WhisperModel.find(id)?.name ?? id)
    }

    @ViewBuilder private var actions: some View {
        if record.status == .failed {
            if retrying { ProgressView().controlSize(.small) }
            else { Button("Retry", action: onRetry).controlSize(.small) }
        } else {
            Button(copied ? "Copied" : "Copy") {
                TextInserter.copyToClipboard(record.text)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            }.controlSize(.small)
            if !record.rawText.isEmpty && record.rawText != record.text {
                Button(showOriginal ? "Hide original" : "Original") { showOriginal.toggle() }.controlSize(.small)
            }
        }
        Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
            .controlSize(.small).help("Delete")
    }
}

private struct Tag: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10.5, weight: .medium)).foregroundColor(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}
