import SwiftUI

extension WindowCoordinator {
    func showAddURL() {
        let key = "add-url"
        show(key: key, title: String(localized: "Enter New Address to Download")) {
            AddURLView(close: { [weak self] in self?.close(key: key) })
        }
    }

    func showDownloadInfo(_ pending: PendingDownload) {
        let key = "info-\(pending.id.uuidString)"
        show(key: key, title: String(localized: "Download File Info")) {
            DownloadInfoView(pending: pending, close: { [weak self] in self?.close(key: key) })
        }
    }

    func showVideoInfo(_ pending: PendingDownload) {
        let key = "video-\(pending.id.uuidString)"
        show(key: key, title: String(localized: "Download Video")) {
            VideoInfoView(pending: pending, close: { [weak self] in self?.close(key: key) })
        }
    }

    func showProgress(_ id: UUID) {
        show(key: Self.progressKey(id), title: model.manager.item(id)?.fileName ?? "") {
            ProgressWindowView(id: id)
        }
    }

    func showCompletion(_ id: UUID) {
        guard let item = model.manager.item(id) else { return }
        let key = "done-\(id.uuidString)"
        show(key: key, title: String(localized: "Download complete")) {
            CompletionView(item: item, close: { [weak self] in self?.close(key: key) })
        }
    }
}
