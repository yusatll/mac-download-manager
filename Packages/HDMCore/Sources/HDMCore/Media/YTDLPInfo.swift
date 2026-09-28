import Foundation

/// The subset of `yt-dlp -J` output HDM cares about.
public struct YTDLPInfo: Sendable, Equatable, Decodable {
    public struct Format: Sendable, Equatable, Decodable {
        public var id: String
        public var ext: String?
        public var vcodec: String?
        public var acodec: String?
        public var height: Int?
        public var width: Int?
        public var fps: Double?
        public var filesize: Int64?
        public var filesizeApprox: Int64?
        /// Average bitrate in kbps, when yt-dlp reports one.
        public var tbr: Double?
        public var note: String?

        enum CodingKeys: String, CodingKey {
            case id = "format_id", ext, vcodec, acodec, height, width, fps
            case filesize, filesizeApprox = "filesize_approx", tbr
            case note = "format_note"
        }

        public init(id: String, ext: String? = nil, vcodec: String? = nil, acodec: String? = nil,
                    height: Int? = nil, width: Int? = nil, fps: Double? = nil,
                    filesize: Int64? = nil, filesizeApprox: Int64? = nil, tbr: Double? = nil, note: String? = nil) {
            self.id = id
            self.ext = ext
            self.vcodec = vcodec
            self.acodec = acodec
            self.height = height
            self.width = width
            self.fps = fps
            self.filesize = filesize
            self.filesizeApprox = filesizeApprox
            self.tbr = tbr
            self.note = note
        }

        public var hasVideo: Bool { vcodec.flatMap { $0.lowercased() != "none" } ?? false }
        public var hasAudio: Bool { acodec.flatMap { $0.lowercased() != "none" } ?? false }
        public var knownSize: Int64? { filesize ?? filesizeApprox }
        public var codecName: String? {
            guard let vcodec, !vcodec.isEmpty, vcodec.lowercased() != "none" else { return nil }
            let name = vcodec.split(separator: ".").first.map(String.init)?.lowercased() ?? vcodec.lowercased()
            return Self.knownCodecs[name] ?? name
        }

        static let knownCodecs = ["avc1": "H.264", "avc3": "H.264", "h264": "H.264",
                                  "vp09": "VP9", "vp9": "VP9", "vp8": "VP8",
                                  "av01": "AV1", "av1": "AV1", "hevc": "HEVC"]
    }

    public var title: String?
    public var duration: Double?
    public var uploader: String?
    public var formats: [Format]
    public var isLive: Bool
    /// Direct-file results (no `formats` array) keep their single format at the top level.
    public var topLevelFormat: Format?
    /// Set when the JSON is a playlist (`_type: "playlist"`): its own title and the
    /// (flat) entries. Flat entries carry id/title/duration but no formats.
    public var playlistTitle: String?
    public var flatEntries: [FlatEntry]

    /// One entry of a `--flat-playlist` result.
    public struct FlatEntry: Decodable, Sendable, Equatable {
        public var id: String?
        public var title: String?
        public var duration: Double?
        public var url: String?

        enum CodingKeys: String, CodingKey { case id, title, duration, url }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            duration = try c.decodeIfPresent(Double.self, forKey: .duration)
            url = try c.decodeIfPresent(String.self, forKey: .url)
        }
    }

    public var isPlaylist: Bool { !flatEntries.isEmpty || playlistCount != nil }
    public var playlistCount: Int?

    enum CodingKeys: String, CodingKey {
        case title, duration, uploader, formats, entries, url, _type
        case playlistCount = "playlist_count"
        case isLive = "live_status"
        case id = "format_id", ext, vcodec, acodec, height
        case filesize, filesizeApprox = "filesize_approx", tbr
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var title = try c.decodeIfPresent(String.self, forKey: .title)
        var duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        var uploader = try c.decodeIfPresent(String.self, forKey: .uploader)
        var formats = try c.decodeIfPresent([Format].self, forKey: .formats) ?? []
        var isLive: Bool
        switch try c.decodeIfPresent(String.self, forKey: .isLive) {
        case "is_live", "post_live": isLive = true
        default: isLive = false
        }
        var topLevelFormat: Format?
        var playlistTitle: String?
        var flatEntries: [FlatEntry] = []
        var playlistCount = try c.decodeIfPresent(Int.self, forKey: .playlistCount)

        if let type = try c.decodeIfPresent(String.self, forKey: ._type), type == "playlist" {
            playlistTitle = title
            if let entries = try c.decodeIfPresent([FlatEntry].self, forKey: .entries) {
                flatEntries = entries
                if playlistCount == nil { playlistCount = entries.count }
            }
            if title == nil, let first = flatEntries.first { title = first.title }
            duration = flatEntries.compactMap(\.duration).reduce(0, +)
        } else if formats.isEmpty, let entries = try c.decodeIfPresent([YTDLPInfo].self, forKey: .entries), let first = entries.first {
            // A playlist JSON wraps videos in `entries`; with --no-playlist HDM shows the first video (§8.3).
            title = first.title ?? title   // the entry is what gets downloaded; prefer its metadata
            duration = first.duration ?? duration
            uploader = first.uploader ?? uploader
            formats = first.formats
            topLevelFormat = first.topLevelFormat
            isLive = isLive || first.isLive
        } else if formats.isEmpty {
            // Direct media file: its only format is described at the top level of the JSON.
            let id = try c.decodeIfPresent(String.self, forKey: .id)
            if id != nil || (try? c.decodeIfPresent(String.self, forKey: .url)) != nil {
                topLevelFormat = Format(
                    id: id ?? "0",
                    ext: try c.decodeIfPresent(String.self, forKey: .ext),
                    vcodec: try c.decodeIfPresent(String.self, forKey: .vcodec),
                    acodec: try c.decodeIfPresent(String.self, forKey: .acodec),
                    height: try c.decodeIfPresent(Int.self, forKey: .height),
                    filesize: try c.decodeIfPresent(Int64.self, forKey: .filesize),
                    filesizeApprox: try c.decodeIfPresent(Int64.self, forKey: .filesizeApprox),
                    tbr: try c.decodeIfPresent(Double.self, forKey: .tbr))
            }
        }
        self.init(title: title, duration: duration, uploader: uploader, formats: formats,
                  topLevelFormat: topLevelFormat, isLive: isLive,
                  playlistTitle: playlistTitle, flatEntries: flatEntries, playlistCount: playlistCount)
    }

    init(title: String?, duration: Double?, uploader: String?, formats: [Format], topLevelFormat: Format?, isLive: Bool,
         playlistTitle: String? = nil, flatEntries: [FlatEntry] = [], playlistCount: Int? = nil) {
        self.title = title
        self.duration = duration
        self.uploader = uploader
        self.formats = formats
        self.topLevelFormat = topLevelFormat
        self.isLive = isLive
        self.playlistTitle = playlistTitle
        self.flatEntries = flatEntries
        self.playlistCount = playlistCount
    }

    /// All playable formats: the `formats` array, or the single top-level format of a direct file.
    public var allFormats: [Format] {
        if formats.isEmpty, let single = topLevelFormat { return [single] }
        return formats.filter { $0.hasVideo || $0.hasAudio }
    }
}
