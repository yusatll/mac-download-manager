import AppKit
import HDMCore
import SwiftUI

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(DownloadManager.self) private var manager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let active = manager.items.filter { $0.status.isRunning }
        if active.isEmpty {
            Text("No active downloads")
        } else {
            ForEach(active) { item in
                Button(item.fileName + "  " + Format.percent(item.fractionCompleted)) { model.windows.showProgress(item.id) }
            }
        }
        Divider()
        Button("Add URL…") { model.windows.showAddURL() }
        Button("Stop All") { model.stopAll() }.disabled(active.isEmpty)
        Divider()
        Button("Open Hiz Download Manager") {
            openWindow(id: "main")
            NSApp.activate()
        }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Hiz Download Manager") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct MenuBarLabel: View {
    let manager: DownloadManager

    var body: some View {
        let speed = manager.totalBytesPerSecond
        if manager.activeCount > 0, speed > 0 {
            Label(Format.speed(speed), systemImage: "arrow.down.circle.fill").labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "arrow.down.circle")
        }
    }
}
