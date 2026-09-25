import AppKit
import HDMCore
import Observation
import SwiftUI

@MainActor @Observable
final class AppModel {
    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored let manager: DownloadManager
    @ObservationIgnored private(set) var windows: WindowCoordinator!
    @ObservationIgnored private(set) var capture: CaptureCoordinator!
    @ObservationIgnored var openMainWindowAction: OpenWindowAction?
    @ObservationIgnored private var clipboard: ClipboardMonitor?

    init() {
        settings = SettingsStore()
        manager = DownloadManager(store: DownloadStore(), settings: settings)
        windows = WindowCoordinator(model: self)
        capture = CaptureCoordinator(model: self)
    }

    func start() {
        clipboard = ClipboardMonitor(
            isEnabled: { [unowned self] in settings.settings.clipboardMonitoring },
            shouldCapture: { [unowned self] url in settings.settings.shouldCapture(fileName: url.lastPathComponent) },
            onURL: { [unowned self] url in capture.handle(PendingDownload(url: url, source: .clipboard)) })
        clipboard?.start()
    }

    func showMainWindow() {
        openMainWindowAction?(id: "main")
        NSApp.activate()
    }
}
