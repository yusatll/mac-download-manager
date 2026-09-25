import HDMCore
import SwiftUI

struct MainToolbar: ToolbarContent {
    let model: AppModel
    let manager: DownloadManager
    let selection: Set<UUID>

    private var selected: [DownloadItem] { selection.compactMap(manager.item) }

    var body: some ToolbarContent {
        ToolbarItemGroup {
            Button { model.windows.showAddURL() } label: { Label("Add URL", systemImage: "plus.circle") }
            Button { model.resume(selection) } label: { Label("Resume", systemImage: "play.fill") }
                .disabled(!selected.contains { $0.status.canResume })
            Button { model.stop(selection) } label: { Label("Stop", systemImage: "stop.fill") }
                .disabled(!selected.contains { $0.status.isRunning || $0.status == .queued })
            Button { model.stopAll() } label: { Label("Stop All", systemImage: "stop.circle") }
            Button { model.confirmDelete(selection) } label: { Label("Delete", systemImage: "trash") }
                .disabled(selection.isEmpty)
            Button { model.confirmDeleteCompleted() } label: { Label("Delete Completed", systemImage: "checkmark.rectangle.stack") }
            SettingsLink { Label("Options", systemImage: "gearshape") }
            Button { manager.startQueue() } label: { Label("Start Queue", systemImage: "forward.end.fill") }
            Button { manager.stopQueue() } label: { Label("Stop Queue", systemImage: "pause.rectangle") }
        }
    }
}
