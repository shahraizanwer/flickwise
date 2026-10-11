// MyProgressView — the My Progress page: how many mistakes your tracked fixes corrected, by type,
// your most repeated corrections, and an 8-week trend. Port of the Progress tab in lib/history_window.lua.
import SwiftUI

struct MyProgressView: View {
    @ObservedObject private var store = HistoryStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @State private var stats = ProgressStats()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("My Progress").font(.title2.weight(.semibold))
                    Text("Counts corrections made by \(settings.settings.history.mistakeModes.joined(separator: " and ")). Undone fixes don't count.")
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 12) {
                    tile("\(stats.thisWeek.fixes)", "fixes this week", compare: stats.lastWeek.fixes, lowerIsBetter: false)
                    tile("\(stats.thisWeek.mistakes)", "mistakes this week", compare: stats.lastWeek.mistakes, lowerIsBetter: true)
                    tile(perFix, "mistakes per fix", compare: nil, lowerIsBetter: true)
                }
                section("Last 8 weeks") { weeksChart }
                section("Mistakes by type") {
                    if stats.categories.isEmpty { empty("No tracked fixes yet. Use Fix Grammar or Minimal Fix and they'll show up here.") }
                    ForEach(stats.categories) { c in categoryRow(c) }
                }
                section("Your most repeated corrections") {
                    if stats.top.isEmpty { empty("Nothing repeated yet.") }
                    ForEach(stats.top) { r in
                        HStack {
                            Text(r.from.isEmpty ? "∅" : r.from).strikethrough().foregroundColor(.red.opacity(0.85))
                            Image(systemName: "arrow.right").font(.caption).foregroundColor(.secondary)
                            Text(r.to.isEmpty ? "∅" : r.to).foregroundColor(.green)
                            Text(r.cat).font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Text("×\(r.count)").font(.system(.body, design: .rounded)).monospacedDigit()
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .onAppear(perform: reload)
        .onReceive(store.$revision) { _ in reload() }
    }

    private var perFix: String {
        stats.thisWeek.fixes == 0 ? "—" : String(format: "%.1f", Double(stats.thisWeek.mistakes) / Double(stats.thisWeek.fixes))
    }

    private func reload() {
        stats = ProgressStats.compute(HistoryStore.shared.trackedFixes(since: .distantPast))
    }

    private func tile(_ value: String, _ label: String, compare: Int?, lowerIsBetter: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded))
            Text(label).font(.caption).foregroundColor(.secondary)
            if let compare {
                let current = Int(value) ?? 0
                let delta = current - compare
                let good = lowerIsBetter ? delta <= 0 : delta >= 0
                Text(delta == 0 ? "same as last week" : "\(delta > 0 ? "+" : "")\(delta) vs last week")
                    .font(.caption2).foregroundColor(delta == 0 ? .secondary : (good ? .green : .orange))
            } else {
                Text("this week").font(.caption2).foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }

    private var weeksChart: some View {
        let maxValue = max(1, stats.weeks.map { max($0.fixes, $0.mistakes) }.max() ?? 1)
        return HStack(alignment: .bottom, spacing: 14) {
            ForEach(stats.weeks) { w in
                VStack(spacing: 4) {
                    HStack(alignment: .bottom, spacing: 3) {
                        bar(w.fixes, maxValue, Flicky.cyan)
                        bar(w.mistakes, maxValue, Flicky.violet)
                    }
                    .frame(height: 90, alignment: .bottom)
                    Text(w.label).font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 10) {
                Label("fixes", systemImage: "square.fill").foregroundColor(Flicky.cyan)
                Label("mistakes", systemImage: "square.fill").foregroundColor(Flicky.violet)
            }.font(.caption2).labelStyle(.titleAndIcon).offset(y: -26)
        }
    }

    private func bar(_ v: Int, _ maxValue: Int, _ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(color.gradient)
            .frame(width: 10, height: max(2, CGFloat(v) / CGFloat(maxValue) * 90))
    }

    private func categoryRow(_ c: ProgressStats.Category) -> some View {
        let maxTotal = max(1, stats.categories.first?.total ?? 1)
        return HStack(spacing: 10) {
            Text(c.name).frame(width: 220, alignment: .leading)
            GeometryReader { g in
                RoundedRectangle(cornerRadius: 3).fill(LinearGradient(colors: [Flicky.violet, Flicky.cyan], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(4, g.size.width * CGFloat(c.total) / CGFloat(maxTotal)))
            }.frame(height: 8)
            Text("\(c.total)").monospacedDigit().frame(width: 34, alignment: .trailing)
            Text(c.week > 0 ? "+\(c.week) this week" : "").font(.caption).foregroundColor(.secondary).frame(width: 90, alignment: .leading)
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text).foregroundColor(.secondary).font(.callout)
    }
}
