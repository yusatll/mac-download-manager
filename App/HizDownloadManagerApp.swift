import HDMCore
import SwiftUI

@main
struct HizDownloadManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        let model = appDelegate.model
        Window("Hiz Download Manager", id: "main") {
            MainView()
                .environment(model)
                .environment(model.manager)
                .frame(minWidth: 900, minHeight: 480)
        }
        .defaultSize(width: 1200, height: 650)
        .windowToolbarStyle(.expanded)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
                .environment(model.manager)
        }
    }
}
