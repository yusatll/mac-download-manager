import Foundation

/// Parsed `HDM|` progress line emitted by the `--progress-template` we pass to yt-dlp (spec §8.3).
public struct MediaProgressLine: Equatable, Sendable {
    public var downloadedBytes: Int64
    public var totalBytes: Int64?
    public var speed: Double?
    public var etaSeconds: Double?

    public init(downloadedBytes: Int64, totalBytes: Int64?, speed: Double?, etaSeconds: Double?) {
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.speed = speed
        self.etaSeconds = etaSeconds
    }
}

/// Reads yt-dlp's stdout: progress template lines, post-processing markers and final-path hints.
public enum ProgressParser {
    static let prefix = "HDM|"

    /// `HDM|123456|NA|123456|204800.5|12` — fields yt-dlp does not know print as `NA`.
    public static func progress(_ line: String) -> MediaProgressLine? {
        guard line.hasPrefix(prefix) else { return nil }
        let fields = line.dropFirst(prefix.count).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 4, let downloaded = Int64(clean(fields[0])) else { return nil }
        let total = Int64(clean(fields[1])) ?? Int64(clean(fields[2]))
        let speed = Double(clean(fields[3]))
        let eta = fields.count > 4 ? Double(clean(fields[4])) : nil
        return MediaProgressLine(downloadedBytes: downloaded, totalBytes: total,
                                 speed: speed.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
                                 etaSeconds: eta.flatMap { $0.isFinite && $0 > 0 ? $0 : nil })
    }

    /// `[Merger]`, `[ExtractAudio]`, `[VideoRemuxer]`, `[Metadata]` … mark the post-processing phase.
    public static func isPostProcessing(_ line: String) -> Bool {
        for marker in ["[Merger]", "[ExtractAudio]", "[VideoRemuxer]", "[EmbedSubtitle]", "[Metadata]"] {
            if line.contains(marker) { return true }
        }
        return false
    }

    /// Paths yt-dlp prints that identify the finished file:
    /// `[Merger] Merging formats into "path"`, `[ExtractAudio] Destination: path`,
    /// `[download] path has already been downloaded`. yt-dlp prints filesystem paths, which may
    /// contain spaces, so these are parsed as file paths, not URL strings.
    public static func finalPathHint(_ line: String) -> URL? {
        guard line.contains("[Merger]") || line.contains("[ExtractAudio]") || line.contains("[VideoRemuxer]")
                || line.contains("has already been downloaded") || line.contains("[download] Destination:")
        else { return nil }
        let quoted = line.drop(while: { $0 != "\"" }).dropFirst().prefix(while: { $0 != "\"" })
        if !quoted.isEmpty { return URL(fileURLWithPath: String(quoted), isDirectory: false) }
        if let destination = line.range(of: "Destination: ") {
            let raw = line[destination.upperBound...].trimmingCharacters(in: .whitespaces)
            if !raw.isEmpty { return URL(fileURLWithPath: raw, isDirectory: false) }
        }
        if let already = line.range(of: " has already been downloaded") {
            let raw = line[line.startIndex..<already.lowerBound]
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "[download] ", with: "")
            if !raw.isEmpty { return URL(fileURLWithPath: raw, isDirectory: false) }
        }
        return nil
    }

    private static func clean(_ field: String) -> String {
        field.trimmingCharacters(in: .whitespaces)
    }
}
