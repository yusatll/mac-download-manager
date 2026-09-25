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
}
