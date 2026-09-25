import SwiftUI

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add URL…") { model.windows.showAddURL() }.keyboardShortcut("n")
        }
        CommandMenu("Downloads") {
            Button("Stop All") { model.stopAll() }.keyboardShortcut(".", modifiers: [.command, .shift])
            Divider()
            Button("Start Queue") { model.manager.startQueue() }
            Button("Stop Queue") { model.manager.stopQueue() }
        }
    }
}
