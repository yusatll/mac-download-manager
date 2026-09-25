import AppKit
import HDMCore

@MainActor
final class CaptureCoordinator {
    unowned let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    func handle(_ pending: PendingDownload) {
        guard ["http", "https"].contains(pending.url.scheme?.lowercased() ?? "") else { return }
        if model.settings.settings.startWithoutDialog {
            Task { await startImmediately(pending) }
        } else {
            model.windows.showDownloadInfo(pending)
        }
    }

    /// If `pending` looks like the new address of a download that is waiting for one, asks the user and applies it.
    func offerRefresh(_ pending: PendingDownload, fileName: String, totalBytes: Int64?) -> Bool {
        guard let candidate = model.manager.refreshCandidate(fileName: fileName, totalBytes: totalBytes) else { return false }
        let alert = NSAlert()
        alert.messageText = String(localized: "Is this the new address for “\(candidate.fileName)”?")
        alert.informativeText = String(localized: "HDM is waiting for a new link for this download. Use this address and continue where it left off?")
        alert.addButton(withTitle: String(localized: "Use New Address"))
        alert.addButton(withTitle: String(localized: "New Download"))
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        model.manager.applyRefreshedLink(candidate.id, url: pending.url, headers: pending.headers,
                                         pageURL: pending.pageURL, referrer: pending.referrer)
        return true
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    if let link = Self.resolveDroppedURL(url) {
                        self.handle(PendingDownload(url: link, source: .drop))
                    }
                }
            }
        }
        return accepted
    }

    /// Web links pass through; `.webloc` files are unwrapped to the link they contain.
    private static func resolveDroppedURL(_ url: URL) -> URL? {
        guard url.isFileURL else { return url }
        guard url.pathExtension.lowercased() == "webloc",
              let plist = NSDictionary(contentsOf: url), let string = plist["URL"] as? String else { return nil }
        return URL(string: string)
    }

    private func startImmediately(_ pending: PendingDownload) async {
        let probe = try? await HTTPProbe.probe(url: pending.url, headers: pending.headers)
        let name = FilenameResolver.resolve(contentDisposition: probe?.contentDisposition, suggested: pending.suggestedName,
                                            url: probe?.finalURL ?? pending.url, mimeType: probe?.mimeType)
        if offerRefresh(pending, fileName: name, totalBytes: probe?.totalBytes ?? pending.totalBytes) { return }
        let s = model.settings.settings
        let category = s.categoryResolver.category(forFileName: name)
        let directory = s.folder(for: category)
        let finalName = s.conflictPolicy == .overwrite ? name : FilenameResolver.uniqueName(name, in: directory)
        model.manager.add(NewDownload(url: pending.url, fileName: finalName, directory: directory, category: category,
                                      headers: pending.headers, pageURL: pending.pageURL, referrer: pending.referrer,
                                      totalBytes: probe?.totalBytes ?? pending.totalBytes))
    }
}
