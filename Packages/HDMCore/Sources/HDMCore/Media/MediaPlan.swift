import Foundation

/// Everything one yt-dlp download run needs (spec §8.3). Mirrors `DownloadRequest` for media items.
public struct MediaRequest: Sendable, Equatable {
    public var sourceURL: URL
    public var formatSelector: String
    public var sortSpec: String?
    public var audioOnly: Bool
    /// Download the whole playlist at `sourceURL` into `directory` (one subfolder per job).
    public var playlist: Bool
    public var directory: URL
    /// File base name without extension; yt-dlp appends `.%(ext)s`. For playlists this is a
    /// yt-dlp output template (e.g. `%(playlist_index)03d - %(title).190B`).
    public var baseName: String
    public var approxTotalBytes: Int64?
    public var headers: [String: String]
    public var tools: ComponentPaths
    public var concurrentFragments: Int
    /// Bytes per second; 0 means unlimited.
    public var speedLimitBytesPerSecond: Int64

    public init(sourceURL: URL, formatSelector: String, sortSpec: String? = nil, audioOnly: Bool,
                playlist: Bool = false,
                directory: URL, baseName: String, approxTotalBytes: Int64? = nil, headers: [String: String] = [:],
                tools: ComponentPaths, concurrentFragments: Int = 8, speedLimitBytesPerSecond: Int64 = 0) {
        self.sourceURL = sourceURL
        self.formatSelector = formatSelector
        self.sortSpec = sortSpec
        self.audioOnly = audioOnly
        self.playlist = playlist
        self.directory = directory
        self.baseName = baseName
        self.approxTotalBytes = approxTotalBytes
        self.headers = headers
        self.tools = tools
        self.concurrentFragments = concurrentFragments
        self.speedLimitBytesPerSecond = speedLimitBytesPerSecond
    }
}

/// Builds the yt-dlp argument vector as a pure function so it is fully unit-testable.
/// Arguments are always passed as an array to `Process`; no shell is involved (spec §10).
public enum MediaPlan {
    public static let progressTemplate =
        "download:HDM|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s"

    public static func arguments(for request: MediaRequest) -> [String] {
        var args = [
            "-f", request.formatSelector,
            request.playlist ? "--yes-playlist" : "--no-playlist",
            "--continue",
            "--newline",
            "--no-update",
            "--no-warnings",
            "-N", String(max(1, request.concurrentFragments)),
            "--progress-template", progressTemplate,
        ]
        if let sort = request.sortSpec, !sort.isEmpty {
            args += ["-S", sort]
        }
        if request.speedLimitBytesPerSecond > 0 {
            args += ["-r", rateLimit(request.speedLimitBytesPerSecond)]
        }
        if let ffmpeg = request.tools.ffmpeg {
            args += ["--ffmpeg-location", ffmpeg.deletingLastPathComponent().path]
        }
        if let deno = request.tools.deno {
            args += ["--js-runtimes", "deno:\(deno.deletingLastPathComponent().path)"]
        }
        if request.audioOnly {
            args += ["-x", "--audio-format", "m4a"]
        } else {
            args += ["--merge-output-format", "mp4"]
        }
        args += [
            "--print", "after_move:filepath",
            "--no-simulate",
            "--no-quiet",
            "-o", request.directory.appendingPathComponent(request.baseName + ".%(ext)s").path,
        ]
        for (name, value) in request.headers.sorted(by: { $0.key < $1.key }) {
            args += ["--add-header", "\(name): \(value)"]
        }
        args.append(request.sourceURL.absoluteString)
        return args
    }

    /// yt-dlp's `-r` syntax: a plain byte count or `K`/`M`/`G` suffix.
    public static func rateLimit(_ bytesPerSecond: Int64) -> String {
        let units: [(suffix: String, bytes: Int64)] = [("G", 1 << 30), ("M", 1 << 20), ("K", 1 << 10)]
        for unit in units where bytesPerSecond >= unit.bytes && bytesPerSecond % unit.bytes == 0 {
            return "\(bytesPerSecond / unit.bytes)\(unit.suffix)"
        }
        return String(bytesPerSecond)
    }
}
