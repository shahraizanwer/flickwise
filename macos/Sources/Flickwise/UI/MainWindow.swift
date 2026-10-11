// MainWindow — the Flickwise app window: a sidebar of pages (History, My Progress, Modes,
// Dictation, Features, AI, General). The menu bar and shortcuts open it at a given page.
import SwiftUI

final class MainNav: ObservableObject {
    static let shared = MainNav()

    enum Page: String, CaseIterable, Identifiable {
        case history = "History", progress = "My Progress", modes = "Modes"
        case dictation = "Dictation", features = "Features", ai = "AI", general = "General"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .history: return "clock.arrow.circlepath"
            case .progress: return "chart.bar.xaxis"
            case .modes: return "wand.and.stars"
            case .dictation: return "waveform"
            case .features: return "switch.2"
            case .ai: return "sparkles"
            case .general: return "gearshape"
            }
        }
    }

    @Published var page: Page = .history
}

struct MainWindowView: View {
    @ObservedObject private var nav = MainNav.shared

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { nav.page }, set: { if let p = $0 { nav.page = p } })) {
                Section {
                    ForEach([MainNav.Page.history, .progress]) { row($0) }
                }
                Section("Customize") {
                    ForEach([MainNav.Page.modes, .dictation, .features, .ai, .general]) { row($0) }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
        } detail: {
            switch nav.page {
            case .history: HistoryView()
            case .progress: MyProgressView()
            case .modes: ModesView()
            case .dictation: DictationPane()
            case .features: FeaturesPane()
            case .ai: AIPane()
            case .general: GeneralPane()
            }
        }
        .frame(minWidth: 820, minHeight: 560)
    }

    private func row(_ p: MainNav.Page) -> some View {
        Label(p.rawValue, systemImage: p.icon).tag(p)
    }
}
