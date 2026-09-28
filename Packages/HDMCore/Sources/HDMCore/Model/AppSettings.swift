import Foundation

public enum ConflictPolicy: String, Codable, Sendable, CaseIterable { case rename, overwrite, ask }

public struct AppSettings: Codable, Equatable, Sendable {
    public var maxConnections = 8
    public var maxConcurrentDownloads = 4
    /// Bytes per second; 0 means unlimited.
    public var globalSpeedLimit: Int64 = 0
    public var retryCount = 10
    public var timeoutSeconds: Double = 30
    public var baseFolder: URL = AppSettings.defaultBaseFolder
    public var categoryFolders: [DownloadCategory: URL] = [:]
    public var categoryExtensions: [DownloadCategory: [String]] = DownloadCategory.defaultExtensions
    public var captureExtensions: [String] = AppSettings.defaultCaptureExtensions
    public var clipboardMonitoring = true
    public var startWithoutDialog = false
    public var showProgressWindow = true
    public var showCompletionDialog = true
    public var keepInMenuBar = true
    public var preventSleep = true
    public var conflictPolicy: ConflictPolicy = .rename
    /// Prefer H.264/AAC formats so downloads open in QuickTime (spec §8.3).
    public var preferQuickTimeCompatible = true

    public static let defaultBaseFolder = FileManager.default
        .urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("HDM", isDirectory: true)

    public static let defaultCaptureExtensions = [
        "3gp", "7z", "aac", "apk", "avi", "bz2", "dmg", "doc", "docx", "epub", "exe", "flac", "flv", "gz",
        "iso", "m4a", "m4v", "mkv", "mov", "mp3", "mp4", "mpeg", "mpg", "msi", "ogg", "opus", "pdf", "pkg",
        "ppt", "pptx", "rar", "tar", "tgz", "wav", "webm", "wma", "wmv", "xls", "xlsx", "xz", "zip",
    ]

    public init() {}

    public func folder(for category: DownloadCategory) -> URL {
        categoryFolders[category] ?? baseFolder.appendingPathComponent(category.folderName, isDirectory: true)
    }

    public var categoryResolver: CategoryResolver { CategoryResolver(extensions: categoryExtensions) }

    public func shouldCapture(fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return !ext.isEmpty && captureExtensions.contains(ext)
    }

    // Missing keys fall back to defaults so settings from older versions keep loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        maxConnections = try c.decodeIfPresent(Int.self, forKey: .maxConnections) ?? d.maxConnections
        maxConcurrentDownloads = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentDownloads) ?? d.maxConcurrentDownloads
        globalSpeedLimit = try c.decodeIfPresent(Int64.self, forKey: .globalSpeedLimit) ?? d.globalSpeedLimit
        retryCount = try c.decodeIfPresent(Int.self, forKey: .retryCount) ?? d.retryCount
        timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? d.timeoutSeconds
        baseFolder = try c.decodeIfPresent(URL.self, forKey: .baseFolder) ?? d.baseFolder
        categoryFolders = try c.decodeIfPresent([DownloadCategory: URL].self, forKey: .categoryFolders) ?? d.categoryFolders
        categoryExtensions = try c.decodeIfPresent([DownloadCategory: [String]].self, forKey: .categoryExtensions) ?? d.categoryExtensions
        captureExtensions = try c.decodeIfPresent([String].self, forKey: .captureExtensions) ?? d.captureExtensions
        clipboardMonitoring = try c.decodeIfPresent(Bool.self, forKey: .clipboardMonitoring) ?? d.clipboardMonitoring
        startWithoutDialog = try c.decodeIfPresent(Bool.self, forKey: .startWithoutDialog) ?? d.startWithoutDialog
        showProgressWindow = try c.decodeIfPresent(Bool.self, forKey: .showProgressWindow) ?? d.showProgressWindow
        showCompletionDialog = try c.decodeIfPresent(Bool.self, forKey: .showCompletionDialog) ?? d.showCompletionDialog
        keepInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .keepInMenuBar) ?? d.keepInMenuBar
        preventSleep = try c.decodeIfPresent(Bool.self, forKey: .preventSleep) ?? d.preventSleep
        conflictPolicy = try c.decodeIfPresent(ConflictPolicy.self, forKey: .conflictPolicy) ?? d.conflictPolicy
        preferQuickTimeCompatible = try c.decodeIfPresent(Bool.self, forKey: .preferQuickTimeCompatible) ?? d.preferQuickTimeCompatible
    }
}
