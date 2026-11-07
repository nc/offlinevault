import SwiftUI
import OfflineVaultCore

struct Scenario: Codable, Identifiable, Hashable {
    struct Section: Codable, Hashable { var title: String; var items: [Item] }
    struct Item: Codable, Hashable { var text: String; var query: String }
    var id: String; var title: String; var icon: String; var summary: String; var sections: [Section]
    static func load() -> [Scenario] {
        guard let url = Bundle.main.url(forResource: "scenarios", withExtension: "json"), let data = try? Data(contentsOf: url) else { return [] }
        struct Wrapper: Codable { var scenarios: [Scenario] }
        return (try? JSONDecoder().decode(Wrapper.self, from: data).scenarios) ?? []
    }
}

struct ScenariosView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { ScenariosBody(st: model.scenariosScreen) }
}

/// First-24-hours cards: short, printable checklists where every line can be verified against the library.
struct ScenariosBody: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var st: ScenariosScreen
    @State private var scenarios = Scenario.load()

    var body: some View {
        ListDetail {
            List(scenarios, selection: $st.selected) { s in
                Label { VStack(alignment: .leading, spacing: 2) { Text(s.title).font(.headline); Text(s.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2) } } icon: { Image(systemName: s.icon) }.tag(s)
            }
        } detail: {
            if let s = st.selected { card(s) } else { EmptyState(icon: "list.bullet.clipboard", title: "Scenario cards", message: "First-24-hours checklists. Tick items, verify any line against your library, print for the binder.") }
        }
        .navigationTitle(st.selected?.title ?? "Scenarios")
        .navigationSubtitle(st.selected.map { s in "\(doneCount(s)) of \(s.sections.flatMap(\.items).count) done" } ?? "")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { if let s = st.selected { printScenario(s) } } label: { Label("Print", systemImage: "printer") }.disabled(st.selected == nil).keyboardShortcut("p", modifiers: .command).help("Print or save as PDF")
                Button { if let s = st.selected { st.reset(scenario: s.id) } } label: { Label("Reset Checklist", systemImage: "arrow.counterclockwise") }.disabled(st.selected.map { doneCount($0) == 0 } ?? true)
            }
        }
        .onAppear { if st.selected == nil { st.selected = scenarios.first } }
    }

    func doneCount(_ s: Scenario) -> Int { st.checked.filter { $0.hasPrefix(s.id + ":") }.count }

    func card(_ s: Scenario) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(s.summary).foregroundStyle(.secondary)
                ForEach(s.sections, id: \.title) { sec in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(sec.title).font(.headline)
                        ForEach(Array(sec.items.enumerated()), id: \.offset) { i, item in
                            let key = "\(s.id):\(sec.title):\(i)"
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .top, spacing: 8) {
                                    Toggle("", isOn: Binding(get: { st.checked.contains(key) }, set: { st.toggle(key, $0) })).toggleStyle(.checkbox).labelsHidden().accessibilityLabel(item.text)
                                    Text(item.text).strikethrough(st.checked.contains(key), color: .secondary).foregroundStyle(st.checked.contains(key) ? .secondary : .primary).textSelection(.enabled)
                                    Spacer(minLength: 0)
                                    Button { verify(key, item) } label: { st.verifying == key ? AnyView(ProgressView().controlSize(.mini)) : AnyView(Image(systemName: "magnifyingglass")) }.buttonStyle(.borderless).help("Verify this line against your library").accessibilityLabel("Verify in library")
                                }
                                if let src = st.sources[key] {
                                    if src.isEmpty { Text("No library source found yet — add first-aid or preparedness documents.").font(.caption).foregroundStyle(.orange).padding(.leading, 26) }
                                    else { FlowChips(passages: src) { model.open($0) }.padding(.leading, 26) }
                                }
                            }
                        }
                    }
                    .padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
                Label("Starting points written for OfflineVault. Confirm each step against the cited source; instructions from local authorities take precedence.", systemImage: "exclamationmark.shield").font(.caption).foregroundStyle(.secondary)
            }.padding(16).frame(maxWidth: 760, alignment: .leading)
        }
    }

    func verify(_ key: String, _ item: Scenario.Item) {
        st.verifying = key
        Task { let passages = await model.chat.retrieve(item.query); st.sources[key] = passages; st.verifying = nil }
    }
    func printScenario(_ s: Scenario) {
        var text = "\(s.title)\n\(s.summary)\n\n"
        for sec in s.sections { text += "\(sec.title.uppercased())\n"; for it in sec.items { text += "  ☐ \(it.text)\n" }; text += "\n" }
        text += "OfflineVault scenario card. Verify against cited sources; follow local authorities."
        PDFExport.printText(text, title: s.title)
    }
}

struct FlowChips: View {
    let passages: [RetrievedPassage]
    let open: (SourceRef) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(passages.prefix(3)) { p in
                Button { open(p.source) } label: {
                    HStack(spacing: 4) { Image(systemName: p.source.systemImage).font(.caption).accessibilityHidden(true); Text(p.source.title).font(.caption).lineLimit(1); if case .document(_, _, let page) = p.source { Text("p. \(page)").font(.caption).foregroundStyle(.secondary) } }
                    .padding(.horizontal, 8).padding(.vertical, 3).background(Color.accentColor.opacity(0.12), in: Capsule())
                }.buttonStyle(.plain).help(p.text)
            }
        }
    }
}

enum PDFExport {
    @MainActor static func printText(_ text: String, title: String) {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 540, height: 760))
        tv.string = text; tv.font = NSFont.systemFont(ofSize: 11); tv.isVerticallyResizable = true; tv.sizeToFit()
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.topMargin = 36; info.bottomMargin = 36; info.leftMargin = 36; info.rightMargin = 36; info.isVerticallyCentered = false
        let op = NSPrintOperation(view: tv, printInfo: info); op.jobTitle = title; op.showsPrintPanel = true; op.run()
    }
}
