import HDMCore
import SwiftUI

struct ItemContextMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(DownloadManager.self) private var manager
    let ids: Set<UUID>

    var body: some View {
        let items = ids.compactMap(manager.item)
        let single = items.count == 1 ? items.first : nil
        if let single, single.status == .completed {
            Button("Open") { model.open(single) }
            Button("Open With…") { model.openWith(single) }
            Button("Show in Finder") { model.reveal(single) }
            Divider()
        }
        Button("Resume") { model.resume(ids) }
            .disabled(!items.contains { $0.status.canResume })
        Button("Stop") { model.stop(ids) }
            .disabled(!items.contains { $0.status.isRunning || $0.status == .queued })
        Button("Redownload") { ids.forEach { manager.redownload($0) } }
        if let single, single.status != .completed {
            Button("Refresh Download Address") { model.refreshAddress(single) }
        }
        Button("Add to Queue") { manager.addToQueue(ids) }
        Divider()
        Button("Delete…") { model.confirmDelete(ids) }
        if let single {
            Divider()
            Button("Properties…") { model.windows.showProgress(single.id) }
        }
    }
}
