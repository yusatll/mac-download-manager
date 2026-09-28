import Foundation

/// The yt-dlp job attached to a `DownloadItem` whose `kind` is `.media` (spec §8.3).
/// Everything yt-dlp needs to re-run the download after a pause or an app restart.
public struct MediaJob: Hashable, Sendable {
    /// Page or stream URL handed to yt-dlp.
    public var sourceURL: URL
    /// yt-dlp format selector, e.g. `bv*[height<=1080]+ba/b[height<=1080]` or `ba/b`.
    public var formatSelector: String
    /// yt-dlp sort spec (`-S`), e.g. `res,vcodec:h264,acodec:aac`; nil keeps yt-dlp's default.
    public var sortSpec: String?
    public var title: String
    public var audioOnly: Bool
    /// Download every video of the playlist at `sourceURL` into one subfolder.
    public var playlist: Bool
    /// Number of playlist entries, when known (progress totals are estimated from it).
    public var playlistCount: Int?
    /// Sum of the chosen formats' (approximate) sizes, when yt-dlp reported any.
    public var approxTotalBytes: Int64?
    /// Extra request headers for stream URLs (Referer, Origin, …).
    public var headers: [String: String]

    public init(sourceURL: URL, formatSelector: String, sortSpec: String? = nil, title: String,
                audioOnly: Bool, playlist: Bool = false, playlistCount: Int? = nil,
                approxTotalBytes: Int64? = nil, headers: [String: String] = [:]) {
        self.sourceURL = sourceURL
        self.formatSelector = formatSelector
        self.sortSpec = sortSpec
        self.title = title
        self.audioOnly = audioOnly
        self.playlist = playlist
        self.playlistCount = playlistCount
        self.approxTotalBytes = approxTotalBytes
        self.headers = headers
    }
}

extension MediaJob: Codable {
    private enum CodingKeys: String, CodingKey {
        case sourceURL, formatSelector, sortSpec, title, audioOnly, playlist, playlistCount, approxTotalBytes, headers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceURL = try c.decode(URL.self, forKey: .sourceURL)
        formatSelector = try c.decode(String.self, forKey: .formatSelector)
        sortSpec = try c.decodeIfPresent(String.self, forKey: .sortSpec)
        title = try c.decode(String.self, forKey: .title)
        audioOnly = try c.decode(Bool.self, forKey: .audioOnly)
        // Fields added after the first release decode as their defaults (old downloads.json).
        playlist = try c.decodeIfPresent(Bool.self, forKey: .playlist) ?? false
        playlistCount = try c.decodeIfPresent(Int.self, forKey: .playlistCount)
        approxTotalBytes = try c.decodeIfPresent(Int64.self, forKey: .approxTotalBytes)
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
    }
}

/// One row of the quality list the user picks from (spec §8.2).
public struct MediaFormatOption: Identifiable, Hashable, Sendable {
    /// "1080p", "Audio only", …
    public var label: String
    public var selector: String
    public var sortSpec: String?
    /// Container the download will end up in ("MP4", "M4A").
    public var ext: String
    public var approxSize: Int64?
    /// Codec hint, e.g. "VP9/AV1 — VLC/IINA recommended".
    public var note: String?
    public var audioOnly: Bool
    public var height: Int?

    public var id: String { "\(label)-\(selector)" }

    public init(label: String, selector: String, sortSpec: String? = nil, ext: String,
                approxSize: Int64? = nil, note: String? = nil, audioOnly: Bool, height: Int? = nil) {
        self.label = label
        self.selector = selector
        self.sortSpec = sortSpec
        self.ext = ext
        self.approxSize = approxSize
        self.note = note
        self.audioOnly = audioOnly
        self.height = height
    }
}

/// Metadata for one video page, ready to show in the quality dialog.
public struct VideoInfo: Sendable, Equatable {
    public var title: String
    public var duration: TimeInterval?
    public var uploader: String?
    public var options: [MediaFormatOption]
    public var isLive: Bool

    public init(title: String, duration: TimeInterval?, uploader: String?, options: [MediaFormatOption], isLive: Bool) {
        self.title = title
        self.duration = duration
        self.uploader = uploader
        self.options = options
        self.isLive = isLive
    }
}
