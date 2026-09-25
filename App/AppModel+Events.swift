import AppKit
import HDMCore

extension AppModel {
    func handle(_ event: ManagerEvent) {
        switch event {
        case .completed(let id):
            guard let item = manager.item(id) else { return }
            windows.close(key: WindowCoordinator.progressKey(id))
            switch item.onComplete {
            case .open: open(item)
            case .revealInFinder: reveal(item)
            case .nothing: if settings.settings.showCompletionDialog { windows.showCompletion(id) }
            }
        case .started, .failed, .needsRefresh:
            break
        }
    }
}
