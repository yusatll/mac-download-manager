import Foundation

public struct ContentRange: Equatable, Sendable {
    public var start: Int64
    public var end: Int64
    public var total: Int64?

    public init(start: Int64, end: Int64, total: Int64?) {
        self.start = start
        self.end = end
        self.total = total
    }

    /// Parses `bytes a-b/total` or `bytes a-b/*`.
    public init?(header: String?) {
        guard let raw = header?.trimmingCharacters(in: .whitespaces).lowercased(), raw.hasPrefix("bytes") else { return nil }
        let body = raw.dropFirst(5).trimmingCharacters(in: .whitespaces)
        let halves = body.split(separator: "/", maxSplits: 1)
        guard halves.count == 2 else { return nil }
        let bounds = halves[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2, let a = Int64(bounds[0]), let b = Int64(bounds[1]), b >= a else { return nil }
        let total: Int64?
        if halves[1] == "*" { total = nil } else if let t = Int64(halves[1]) { total = t } else { return nil }
        self.init(start: a, end: b, total: total)
    }
}

/// What the first response of a download tells us about the file.
public struct ProbeResult: Equatable, Sendable {
    public var statusCode: Int
    public var totalBytes: Int64?
    public var resumable: Bool
    public var etag: String?
    public var lastModified: String?
    public var contentDisposition: String?
    public var mimeType: String?
    public var finalURL: URL?

    public init(response: HTTPURLResponse) {
        statusCode = response.statusCode
        if response.statusCode == 206 {
            let range = ContentRange(header: response.value(forHTTPHeaderField: "Content-Range"))
            totalBytes = range?.total
            resumable = range?.total != nil
        } else if response.statusCode == 416 {
            totalBytes = ProbeResult.unsatisfiedTotal(response.value(forHTTPHeaderField: "Content-Range"))
            resumable = false
        } else {
            totalBytes = response.expectedContentLength > 0 ? response.expectedContentLength : nil
            resumable = false
        }
        let tag = response.value(forHTTPHeaderField: "ETag")
        etag = (tag?.hasPrefix("W/") ?? true) ? nil : tag   // weak ETags are not valid in If-Range
        lastModified = response.value(forHTTPHeaderField: "Last-Modified")
        contentDisposition = response.value(forHTTPHeaderField: "Content-Disposition")
        mimeType = response.mimeType
        finalURL = response.url
    }

    public var ifRangeValidator: String? { etag ?? lastModified }

    /// Servers answer `bytes=0-` on an empty file with `416` and `Content-Range: bytes */0`.
    public var isEmptyFile: Bool { statusCode == 416 && totalBytes == 0 }

    /// The total from an unsatisfied-range header (`bytes */N`).
    static func unsatisfiedTotal(_ header: String?) -> Int64? {
        guard let raw = header?.trimmingCharacters(in: .whitespaces).lowercased(), raw.hasPrefix("bytes */") else { return nil }
        return Int64(raw.dropFirst("bytes */".count))
    }
}
