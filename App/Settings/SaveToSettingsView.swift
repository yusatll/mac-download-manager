import AppKit
import HDMCore
import SwiftUI

struct SaveToSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var store = model.settings
        Form {
            Section {
                LabeledContent("Base folder:") {
                    FolderField(url: store.settings.baseFolder, onChange: { store.settings.baseFolder = $0 })
                }
            } footer: {
                Text("Categories without their own folder use a subfolder here.")
            }
            Section("Categories") {
                ForEach(DownloadCategory.allCases) { category in
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent {
                            FolderField(url: store.settings.folder(for: category),
                                        onChange: { store.settings.categoryFolders[category] = $0 },
                                        onReset: store.settings.categoryFolders[category] == nil ? nil : { store.settings.categoryFolders[category] = nil })
                        } label: {
                            Label(category.title, systemImage: category.symbol)
                        }
                        if category != .general { ExtensionsField(category: category) }
                    }
                }
            }
            Section {
                Picker("If the file already exists:", selection: $store.settings.conflictPolicy) {
                    Text("Rename the new file").tag(ConflictPolicy.rename)
                    Text("Replace the existing file").tag(ConflictPolicy.overwrite)
                    Text("Ask me").tag(ConflictPolicy.ask)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct FolderField: View {
    let url: URL
    let onChange: (URL) -> Void
    var onReset: (() -> Void)?

    var body: some View {
        HStack {
            Text(url.path(percentEncoded: false)).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
            Button("Choose…") { choose() }
            if let onReset { Button("Reset") { onReset() } }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = url
        if panel.runModal() == .OK, let chosen = panel.url { onChange(chosen) }
    }
}

struct ExtensionsField: View {
    @Environment(AppModel.self) private var model
    let category: DownloadCategory
    @State private var text = ""

    var body: some View {
        TextField("Extensions", text: $text, prompt: Text(verbatim: "zip rar 7z"))
            .font(.caption)
            .onAppear { text = (model.settings.settings.categoryExtensions[category] ?? []).joined(separator: " ") }
            .onChange(of: text) { _, new in
                model.settings.settings.categoryExtensions[category] = GeneralSettingsView.parseExtensions(new)
            }
    }
}
