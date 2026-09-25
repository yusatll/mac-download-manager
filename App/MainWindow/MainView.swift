import HDMCore
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var sidebar: SidebarSelection? = .all(nil)
    @State private var selection = Set<UUID>()
    @State private var search = ""

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $sidebar)
                .navigationSplitViewColumnWidth(min: 170, ideal: 200)
        } detail: {
            DownloadTable(filter: sidebar ?? .all(nil), search: search, selection: $selection)
        }
        .searchable(text: $search, placement: .toolbar)
        .onAppear { model.openMainWindowAction = openWindow }
    }
}
