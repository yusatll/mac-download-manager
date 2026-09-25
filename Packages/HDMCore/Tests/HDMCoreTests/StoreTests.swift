import Foundation
import Testing
@testable import HDMCore

@Suite struct StoreTests {
    func sample() -> DownloadItem {
        var item = DownloadItem(url: URL(string: "https://e.com/a.zip")!, fileName: "a.zip",
                                saveDirectory: URL(fileURLWithPath: "/tmp"), category: .compressed,
                                headers: ["Cookie": "s=1"])
        item.segments = [Segment(start: 0, end: 100, received: 50)]
        item.status = .paused
        return item
    }

    @Test func roundTripsAndProtectsFile() throws {
        let url = tempDirectory().appendingPathComponent("downloads.json")
        let store = DownloadStore(fileURL: url)
        #expect(store.load().isEmpty)
        let items = [sample(), sample()]
        try store.save(items)
        #expect(store.load() == items)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func fallsBackToBackupWhenMainFileIsCorrupt() throws {
        let url = tempDirectory().appendingPathComponent("downloads.json")
        let store = DownloadStore(fileURL: url)
        let first = [sample()]
        try store.save(first)
        try store.save(first + [sample()])      // first save becomes the .bak
        try Data("{broken".utf8).write(to: url)
        #expect(store.load() == first)
    }

    @MainActor @Test func settingsPersistAndNotify() {
        let suite = "hdm-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        var seen: [Int] = []
        store.onChange = { seen.append($0.maxConnections) }
        store.settings.maxConnections = 16
        store.settings.maxConnections = 16      // unchanged, no second notification
        #expect(seen == [16])
        #expect(SettingsStore(defaults: defaults).settings.maxConnections == 16)
    }
}
