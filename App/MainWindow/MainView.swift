import HDMCore
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(DownloadManager.self) private var manager
    @Environment(\.openWindow) private var openWindow
    @State private var sidebar: SidebarSelection? = .all(nil)
    @State private var selection = Set<UUID>()
    @State private var search = ""

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $sidebar)
                .navigationSplitViewColumnWidth(min: 170, ideal: 200)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            DownloadTable(filter: sidebar ?? .all(nil), search: search, selection: $selection)
        }
        .searchable(text: $search, placement: .toolbar)
        .toolbar { MainToolbar(model: model, manager: manager, selection: selection) }
        .background(WindowAccessor { window in window.toolbar?.displayMode = .iconAndLabel })
        .onDrop(of: [.url], isTargeted: nil) { providers in model.capture.handleDrop(providers) }
        .onAppear { model.openMainWindowAction = openWindow }
    }
}
