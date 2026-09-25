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
