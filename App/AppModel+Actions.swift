import AppKit
import HDMCore

extension AppModel {
    func open(_ item: DownloadItem) { NSWorkspace.shared.open(item.fileURL) }

    func reveal(_ item: DownloadItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.status == .completed ? item.fileURL : item.saveDirectory])
    }

    func openWith(_ item: DownloadItem) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = String(localized: "Open")
        guard panel.runModal() == .OK, let app = panel.url else { return }
        NSWorkspace.shared.open([item.fileURL], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Stops downloads, warning first when a download cannot be resumed (spec §5.4).
    func stop(_ ids: Set<UUID>) {
        let risky = ids.compactMap(manager.item).filter { $0.status.isRunning && $0.resumable == false }
        if !risky.isEmpty {
            let alert = NSAlert()
            alert.messageText = String(localized: "This download cannot be resumed")
            alert.informativeText = String(localized: "The server does not support resuming. If you stop now, the download will start over from the beginning.")
            alert.addButton(withTitle: String(localized: "Stop Anyway"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        Task { await manager.pause(ids) }
    }

    func stopAll() { Task { await manager.pauseAll() } }

    /// Resume, but first resolve failures that repeat on a plain retry (spec §5.4, §5.5):
    /// a changed server file needs a restart, a 401 needs credentials.
    func resume(_ ids: Set<UUID>) {
        var plain: [UUID] = []
        for id in ids {
            guard let item = manager.item(id) else { continue }
            switch item.status {
            case .failed(.serverFileChanged): askToRestart(item)
            case .failed(.authRequired): askForCredentials(item)
            default: plain.append(id)
            }
        }
        manager.resume(plain)
    }

    func askToRestart(_ item: DownloadItem) {
        let alert = NSAlert()
        alert.messageText = String(localized: "The file has changed on the server")
        alert.informativeText = String(localized: "“\(item.fileName)” can't be resumed. Start the download over from the beginning?")
        alert.addButton(withTitle: String(localized: "Start Over"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn { manager.redownload(item.id) }
    }

    func askForCredentials(_ item: DownloadItem) {
        let alert = NSAlert()
        alert.messageText = String(localized: "The server requires a user name and password.")
        alert.informativeText = item.url.host() ?? item.url.absoluteString
        let user = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        user.placeholderString = String(localized: "User name:")
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        password.placeholderString = String(localized: "Password:")
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        fields.addSubview(user)
        fields.addSubview(password)
        alert.accessoryView = fields
        alert.window.initialFirstResponder = user
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn, !user.stringValue.isEmpty else { return }
        let token = Data("\(user.stringValue):\(password.stringValue)".utf8).base64EncodedString()
        manager.setHeader(item.id, name: "Authorization", value: "Basic " + token)
        manager.resume([item.id])
    }

    func confirmDelete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete \(ids.count) download(s)?")
        alert.informativeText = String(localized: "Unfinished parts are always removed.")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Also move downloaded files to the Trash")
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        manager.remove(ids, deleteFiles: alert.suppressionButton?.state == .on)
    }

    func confirmDeleteCompleted() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Remove all completed downloads from the list?")
        alert.informativeText = String(localized: "The files stay on your disk.")
        alert.addButton(withTitle: String(localized: "Remove"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        manager.removeCompleted()
    }

    /// IDM's "Refresh download address": open the page so the user can click the link again (spec §5.5).
    func refreshAddress(_ item: DownloadItem) {
        manager.markAwaitingRefresh(item.id)
        NSWorkspace.shared.open(item.pageURL ?? item.referrer ?? item.url)
        let alert = NSAlert()
        alert.messageText = String(localized: "Waiting for a new link")
        alert.informativeText = String(localized: "Open the page in your browser and click or copy the download link again. HDM will use the new address and continue where it left off.")
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    /// Double-click: open finished files, show the progress window for everything else.
    func primaryAction(for ids: Set<UUID>) {
        guard ids.count == 1, let id = ids.first, let item = manager.item(id) else { return }
        if item.status == .completed { open(item) } else { windows.showProgress(id) }
    }
}
