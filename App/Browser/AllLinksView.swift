import HDMCore
import SwiftUI

/// IDM's "all links" dialog (spec §7.5): checkboxes, type filters and a text filter over the
/// links collected from the page; the selection is queued into the category folders.
struct AllLinksView: View {
    @Environment(AppModel.self) private var model
    let links: [LinkCandidate]
    let pageURL: URL?
    let headers: [String: String]
    let close: () -> Void

    @State private var checked: Set<LinkCandidate.ID> = []
    @State private var typeFilter: DownloadCategory?
    @State private var textFilter = ""

    private struct Row: Identifiable {
        let id: LinkCandidate.ID
        let name: String
        let category: DownloadCategory
        let url: URL
    }

    private var rows: [Row] {
        links.compactMap { link in
            let name = FilenameResolver.resolve(suggested: nil, url: link.url)
            let category = model.settings.settings.categoryResolver.category(forFileName: name)
            return Row(id: link.id, name: link.text.isEmpty ? name : "\(name) — \(link.text)", category: category, url: link.url)
        }
        .filter { row in
            (typeFilter == nil || row.category == typeFilter)
                && (textFilter.isEmpty || row.url.absoluteString.localizedCaseInsensitiveContains(textFilter)
                    || row.name.localizedCaseInsensitiveContains(textFilter))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(pageURL?.host() ?? String(localized: "All links"))
                .font(.headline)
            Picker("", selection: $typeFilter) {
                Text("All").tag(DownloadCategory?.none)
                ForEach(DownloadCategory.allCases) { Text($0.title).tag(DownloadCategory?.some($0)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TextField("Filter", text: $textFilter)
                .textFieldStyle(.roundedBorder)
            Table(rows) {
                TableColumn("") { row in
                    Toggle("", isOn: Binding(
                        get: { checked.contains(row.id) },
                        set: { on in if on { checked.insert(row.id) } else { checked.remove(row.id) } }))
                    .labelsHidden()
                }
                .width(24)
                TableColumn("Name") { row in Text(row.name).lineLimit(1).truncationMode(.middle) }
                TableColumn("Category") { row in Text(row.category.title) }.width(90)
                TableColumn("URL") { row in Text(row.url.absoluteString).lineLimit(1).truncationMode(.middle) }
            }
            .tableStyle(.bordered(alternatesRowBackgrounds: false))
            HStack {
                Button("Select All") { checked = Set(rows.map(\.id)) }
                Button("Select None") { checked.removeAll() }
                Spacer()
                Button("Cancel", role: .cancel) { close() }.keyboardShortcut(.cancelAction)
                Button("Download Selected") { submit() }.keyboardShortcut(.defaultAction).disabled(checked.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 720, height: 460)
        .onAppear { checked = Set(rows.map(\.id)) }
    }

    private func submit() {
        let settings = model.settings.settings
        for row in rows where checked.contains(row.id) {
            let name = FilenameResolver.resolve(suggested: nil, url: row.url)
            model.manager.add(NewDownload(url: row.url, fileName: name, directory: settings.folder(for: row.category),
                                          category: row.category, headers: headers, pageURL: pageURL))
        }
        close()
    }
}
