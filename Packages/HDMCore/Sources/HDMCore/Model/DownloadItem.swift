import Foundation

public enum DownloadKind: String, Codable, Sendable { case http, media }

public enum CompletionAction: String, Codable, Sendable, CaseIterable { case nothing, open, revealInFinder }

public enum FailureReason: Codable, Hashable, Sendable {
    case network(String)
    case http(Int)
    case authRequired
    case serverFileChanged
    case diskFull
    case fileSystem(String)
}

public enum DownloadStatus: Codable, Hashable, Sendable {
    case queued, connecting, downloading, paused, merging, completed
    case failed(FailureReason)
    case needsRefresh

    public var isRunning: Bool {
        switch self {
        case .connecting, .downloading, .merging: true
        default: false
        }
    }

    public var canResume: Bool {
        switch self {
        case .paused, .failed, .needsRefresh: true
        default: false
        }
    }
}

/// One entry of the download list. New fields must be optional (or have custom decoding)
/// so that `downloads.json` written by older versions keeps loading.
public struct DownloadItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: DownloadKind
    public var url: URL
    public var finalURL: URL?
    public var pageURL: URL?
    public var referrer: URL?
    public var headers: [String: String]
    public var fileName: String
    public var saveDirectory: URL
    public var category: DownloadCategory
    public var totalBytes: Int64?
    public var receivedBytes: Int64
    public var resumable: Bool?
    public var etag: String?
    public var lastModified: String?
    public var segments: [Segment]
    public var status: DownloadStatus
    public var autoStart: Bool
    public var maxConnections: Int?
    public var speedLimit: Int64?
    public var onComplete: CompletionAction
    public var createdAt: Date
    public var lastTryAt: Date?
    public var completedAt: Date?
    public var userDescription: String
    public var awaitingRefresh: Bool

    public init(id: UUID = UUID(), url: URL, fileName: String, saveDirectory: URL, category: DownloadCategory,
                headers: [String: String] = [:], pageURL: URL? = nil, referrer: URL? = nil,
                totalBytes: Int64? = nil, userDescription: String = "", autoStart: Bool = true,
                createdAt: Date = Date()) {
        self.id = id
        self.kind = .http
        self.url = url
        self.pageURL = pageURL
        self.referrer = referrer
        self.headers = headers
        self.fileName = fileName
        self.saveDirectory = saveDirectory
        self.category = category
        self.totalBytes = totalBytes
        self.receivedBytes = 0
        self.segments = []
        self.status = .queued
        self.autoStart = autoStart
        self.onComplete = .nothing
        self.createdAt = createdAt
        self.userDescription = userDescription
        self.awaitingRefresh = false
    }

    public var fileURL: URL { saveDirectory.appendingPathComponent(fileName, isDirectory: false) }
    public var partURL: URL { saveDirectory.appendingPathComponent(fileName + ".hdmpart", isDirectory: false) }

    public var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(receivedBytes) / Double(totalBytes))
    }

    /// Forget everything learned about the transfer so it starts from byte 0.
    public mutating func resetTransfer() {
        segments = []
        receivedBytes = 0
        totalBytes = nil
        resumable = nil
        etag = nil
        lastModified = nil
        completedAt = nil
    }
}
