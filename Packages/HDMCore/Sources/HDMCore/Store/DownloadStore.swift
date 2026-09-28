import Foundation

/// Persists the download list as JSON (spec §5.2).
public final class DownloadStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = DownloadStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    public static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacDM", isDirectory: true)
            .appendingPathComponent("downloads.json")
    }

    private var backupURL: URL { fileURL.appendingPathExtension("bak") }

    public func load() -> [DownloadItem] {
        for url in [fileURL, backupURL] {
            if let data = try? Data(contentsOf: url), let items = try? JSONDecoder().decode([DownloadItem].self, from: data) {
                return items
            }
        }
        return []
    }

    public func save(_ items: [DownloadItem]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(items)
        if fm.fileExists(atPath: fileURL.path) {
            try? fm.removeItem(at: backupURL)
            try? fm.copyItem(at: fileURL, to: backupURL)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        }
        try data.write(to: fileURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)   // may contain cookies
    }
}
