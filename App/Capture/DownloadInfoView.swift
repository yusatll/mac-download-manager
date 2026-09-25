import AppKit
import HDMCore
import SwiftUI

/// IDM's "Download File Info" dialog (spec §6.2).
struct DownloadInfoView: View {
    @Environment(AppModel.self) private var model
    let pending: PendingDownload
    let close: () -> Void

    @State private var didAppear = false
    @State private var category: DownloadCategory = .general
    @State private var fileName = ""
    @State private var directory: URL = AppSettings.defaultBaseFolder
    @State private var userEditedName = false
    @State private var userChoseFolder = false
    @State private var rememberFolder = false
    @State private var note = ""
    @State private var size: Int64?
    @State private var probing = true
    @State private var probeError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: FileIcon.icon(for: fileName)).resizable().frame(width: 48, height: 48)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        Text("URL:").gridColumnAlignment(.trailing)
                        Text(pending.url.absoluteString).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                            .frame(maxWidth: 460, alignment: .leading)
                    }
                    GridRow {
                        Text("Category:")
                        Picker("", selection: $category) {
                            ForEach(DownloadCategory.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }
                    GridRow {
                        Text("Save As:")
                        TextField("", text: nameBinding)
                    }
                    GridRow {
                        Text("Folder:")
                        HStack {
                            Text(directory.path(percentEncoded: false)).lineLimit(1).truncationMode(.head)
                                .foregroundStyle(.secondary).frame(maxWidth: 360, alignment: .leading)
                            Button("Choose…") { chooseFolder() }
                        }
                    }
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        Toggle("Remember this folder for this category", isOn: $rememberFolder).disabled(!userChoseFolder)
                    }
                    GridRow {
                        Text("Description:")
                        TextField("", text: $note)
                    }
                    GridRow {
                        Text("Size:")
                        Text(sizeText).foregroundStyle(.secondary)
                    }
                }
            }
            if let probeError {
                Label(probeError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button("Download Later") { submit(start: false) }.disabled(fileName.isEmpty)
                Button("Start Download") { submit(start: true) }.keyboardShortcut(.defaultAction).disabled(fileName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 640)
        .onAppear(perform: prepare)
        .onChange(of: category) { _, new in
            if !userChoseFolder { directory = model.settings.settings.folder(for: new) }
        }
        .task { await probe() }
    }

    private var nameBinding: Binding<String> {
        Binding(get: { fileName }, set: { fileName = $0; userEditedName = true })
    }

    private var sizeText: String {
        if let size { return Format.bytes(size) }
        return probing ? String(localized: "Getting file size…") : String(localized: "Unknown")
    }

    private func prepare() {
        guard !didAppear else { return }
        didAppear = true
        let name = FilenameResolver.resolve(suggested: pending.suggestedName, url: pending.url)
        fileName = name
        size = pending.totalBytes
        applyCategory(for: name)
        directory = model.settings.settings.folder(for: category)
    }

    private func applyCategory(for name: String) {
        category = model.settings.settings.categoryResolver.category(forFileName: name)
    }

    private func probe() async {
        defer { probing = false }
        do {
            let result = try await HTTPProbe.probe(url: pending.url, headers: pending.headers)
            if let total = result.totalBytes { size = total }
            let name = FilenameResolver.resolve(contentDisposition: result.contentDisposition, suggested: pending.suggestedName,
                                                url: result.finalURL ?? pending.url, mimeType: result.mimeType)
            if !userEditedName {
                fileName = name
                applyCategory(for: name)
            }
            if model.capture.offerRefresh(pending, fileName: name, totalBytes: result.totalBytes) { close() }
        } catch ProbeError.http(let code) {
            probeError = String(localized: "The server returned HTTP \(code). You can still try to download.")
        } catch {
            probeError = error.localizedDescription
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = directory
        if panel.runModal() == .OK, let url = panel.url {
            directory = url
            userChoseFolder = true
        }
    }

    private func submit(start: Bool) {
        let fm = FileManager.default
        var name = FilenameResolver.sanitize(fileName)
        let target = directory.appendingPathComponent(name)
        if fm.fileExists(atPath: target.path + ".hdmpart") {
            name = FilenameResolver.uniqueName(name, in: directory)   // never share a part file with another download
        } else if fm.fileExists(atPath: target.path) {
            switch model.settings.settings.conflictPolicy {
            case .rename:
                name = FilenameResolver.uniqueName(name, in: directory)
            case .overwrite:
                break
            case .ask:
                let alert = NSAlert()
                alert.messageText = String(localized: "“\(name)” already exists.")
                alert.informativeText = String(localized: "Do you want to save the new file with a different name or replace the existing one?")
                alert.addButton(withTitle: String(localized: "Rename"))
                alert.addButton(withTitle: String(localized: "Replace"))
                alert.addButton(withTitle: String(localized: "Cancel"))
                switch alert.runModal() {
                case .alertFirstButtonReturn: name = FilenameResolver.uniqueName(name, in: directory)
                case .alertSecondButtonReturn: try? fm.trashItem(at: target, resultingItemURL: nil)
                default: return
                }
            }
        }
        if rememberFolder, userChoseFolder { model.settings.settings.categoryFolders[category] = directory }
        _ = model.manager.add(NewDownload(url: pending.url, fileName: name, directory: directory, category: category,
                                          headers: pending.headers, pageURL: pending.pageURL, referrer: pending.referrer,
                                          totalBytes: size, description: note, autoStart: start))
        close()
    }
}
