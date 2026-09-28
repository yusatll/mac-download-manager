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
    @ObservationIgnored private(set) var browser: BrowserCoordinator!
    @ObservationIgnored var openMainWindowAction: OpenWindowAction?
    @ObservationIgnored let notifier = Notifier()
    @ObservationIgnored private let dock = DockProgress()
    @ObservationIgnored private let sleepGuard = SleepGuard()
    @ObservationIgnored private var clipboard: ClipboardMonitor?
    @ObservationIgnored private var ticker: Timer?

    init() {
        settings = SettingsStore()
        manager = DownloadManager(store: DownloadStore(), settings: settings)
        windows = WindowCoordinator(model: self)
        capture = CaptureCoordinator(model: self)
        browser = BrowserCoordinator(model: self)
    }

    func start() {
        manager.onEvent = { [weak self] event in self?.handle(event) }
        notifier.requestAuthorization()
        browser.start()
        clipboard = ClipboardMonitor(
            isEnabled: { [unowned self] in settings.settings.clipboardMonitoring },
            shouldCapture: { [unowned self] url in
                settings.settings.shouldCapture(fileName: url.lastPathComponent) || MediaSites.isKnownVideoSite(url)
            },
            onURL: { [unowned self] url in capture.handle(PendingDownload(url: url, source: .clipboard)) })
        clipboard?.start()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSystemIndicators() }
        }
        showOnboardingIfNeeded()
    }

    func prepareForTermination() async {
        browser.stop()
        await manager.prepareForTermination()
    }

    private var onboardedKey: String { "MacDM.onboarded.v1" }

    private func showOnboardingIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: onboardedKey) else { return }
        UserDefaults.standard.set(true, forKey: onboardedKey)
        windows.showOnboarding()
    }

    func showMainWindow() {
        openMainWindowAction?(id: "main")
        NSApp.activate()
    }

    private func refreshSystemIndicators() {
        dock.update(fraction: manager.overallFraction, activeCount: manager.activeCount)
        sleepGuard.update(active: settings.settings.preventSleep && manager.activeCount > 0)
    }
}
