import AppKit
import HDMCore

extension AppModel {
    func handle(_ event: ManagerEvent) {
        switch event {
        case .completed(let id):
            guard let item = manager.item(id) else { return }
            windows.close(key: WindowCoordinator.progressKey(id))
            notifier.post(title: String(localized: "Download complete"), body: item.fileName)
            switch item.onComplete {
            case .open: open(item)
            case .revealInFinder: reveal(item)
            case .nothing: if settings.settings.showCompletionDialog { windows.showCompletion(id) }
            }
        case .failed(let id):
            guard let item = manager.item(id), case .failed(let reason) = item.status else { return }
            notifier.post(title: String(localized: "Download failed"), body: item.fileName + " — " + reason.message)
        case .needsRefresh(let id):
            guard let item = manager.item(id) else { return }
            notifier.post(title: String(localized: "Link expired"),
                          body: String(localized: "\(item.fileName) needs a new download link. Right-click it and choose Refresh Download Address."))
        case .started:
            break
        }
    }
}
