import AppKit
import HDMCore
import Observation
import SwiftUI

@MainActor @Observable
final class AppModel {
    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored let manager: DownloadManager
    @ObservationIgnored private(set) var windows: WindowCoordinator!
    @ObservationIgnored var openMainWindowAction: OpenWindowAction?

    init() {
        settings = SettingsStore()
        manager = DownloadManager(store: DownloadStore(), settings: settings)
        windows = WindowCoordinator(model: self)
    }

    func start() {}

    func showMainWindow() {
        openMainWindowAction?(id: "main")
        NSApp.activate()
    }
}
