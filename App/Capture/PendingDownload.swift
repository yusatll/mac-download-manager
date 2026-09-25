import Foundation

/// A link that is about to become a download (from Add URL, clipboard, drag & drop or, later, a browser).
struct PendingDownload: Identifiable, Sendable {
    enum Source: Sendable { case manual, clipboard, drop, browser }

    let id = UUID()
    var url: URL
    var headers: [String: String] = [:]
    var pageURL: URL?
    var referrer: URL?
    var suggestedName: String?
    var totalBytes: Int64?
    var source: Source
}
