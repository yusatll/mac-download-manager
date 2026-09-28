import Foundation

/// Turns a parsed `yt-dlp -J` result into the quality list shown to the user (spec §8.3).
/// One row per available height, plus an "Audio only" row.
///
/// The estimate must match what yt-dlp actually downloads, so every sort spec and the local
/// ranking below are mirror images. YouTube duplicates each itag with an unsized "premium"
/// variant at ~2.4× the bitrate; sorting by `filesize` steers both sides to the size-known
/// format (descending by default; unknown sizes sort last in `-S`), and a `tbr × duration`
/// estimate still fills the display when nothing at a height reports a size.
public enum FormatMapper {
    // No "-" direction prefixes: this yt-dlp build rejects them in -S values, and the
    // default direction is already descending.
    public static let quickTimeSort = "res,vcodec:h264,acodec:aac,filesize"
    public static let compactSort = "res,filesize"
    public static let audioSort = "acodec:aac,filesize"

    public static func videoInfo(from info: YTDLPInfo, preferQuickTimeCompatible: Bool = true) -> VideoInfo {
        VideoInfo(title: info.title ?? "video",
                  duration: info.duration,
                  uploader: info.uploader,
                  options: options(from: info, duration: info.duration,
                                   preferQuickTimeCompatible: preferQuickTimeCompatible),
                  isLive: info.isLive)
    }

    public static func options(from info: YTDLPInfo, duration: Double? = nil,
                               preferQuickTimeCompatible: Bool = true) -> [MediaFormatOption] {
        let sort = preferQuickTimeCompatible ? quickTimeSort : compactSort
        var rows: [MediaFormatOption] = []

        let videoFormats = info.allFormats.filter { $0.hasVideo && $0.height != nil }.map(SizedFormat.init)
        let audioFormats = info.allFormats.filter { $0.hasAudio }.map(SizedFormat.init)
        let bestAudio = bestAudioFormat(in: audioFormats, duration: duration)

        // One row per height, highest first. The selector's fallback branch covers muxed-only
        // sources, so it works whether the site offers adaptive (merge) or muxed (single) formats.
        let heights = Set(videoFormats.compactMap(\.format.height)).sorted(by: >)
        for height in heights {
            let candidates = videoFormats.filter { $0.format.height == height }
            let chosen = pickVideoFormat(candidates, preferH264: preferQuickTimeCompatible) ?? candidates[0]
            let selector = "bv*[height<=\(height)]+ba/b[height<=\(height)]"
            // Estimate = best video at this height + best audio (merged), or the muxed size itself.
            let videoSize = (chosen.format.hasAudio ? nil : chosen.displaySize(duration: duration))
                ?? pickVideoFormat(candidates.filter { !$0.format.hasAudio }, preferH264: preferQuickTimeCompatible)?
                    .displaySize(duration: duration)
                ?? chosen.displaySize(duration: duration)
            let audioSize = chosen.format.hasAudio ? nil : bestAudio?.displaySize(duration: duration)
            let approxSize = sum(videoSize, audioSize) ?? chosen.displaySize(duration: duration)

            var note: String?
            if let codec = chosen.format.codecName, codec != "H.264" {
                let h264Available = candidates.contains { $0.format.codecName == "H.264" }
                if !h264Available { note = "\(codec) — VLC/IINA recommended" }
            }
            rows.append(MediaFormatOption(label: "\(height)p", selector: selector, sortSpec: sort, ext: "MP4",
                                          approxSize: approxSize, note: note, audioOnly: false, height: height))
        }

        if let audio = bestAudio {
            rows.append(MediaFormatOption(label: "Audio only", selector: "ba/b", sortSpec: audioSort, ext: "M4A",
                                          approxSize: audio.displaySize(duration: duration), note: nil,
                                          audioOnly: true, height: nil))
        }

        // A single muxed-only source (e.g. a direct .mp4) still yields one usable row.
        if rows.isEmpty, let only = info.allFormats.first {
            rows.append(MediaFormatOption(label: only.height.map { "\($0)p" } ?? "Original", selector: "b", sortSpec: nil,
                                          ext: (only.ext ?? "mp4").uppercased(), approxSize: only.knownSize,
                                          note: nil, audioOnly: !only.hasVideo, height: only.height))
        }
        return rows
    }

    /// A format paired with its display size: the reported size, or a `tbr × duration`
    /// estimate for the unsized "premium" duplicates.
    struct SizedFormat {
        let format: YTDLPInfo.Format

        var known: Int64? { format.knownSize }

        func displaySize(duration: Double?) -> Int64? {
            if let known { return known }
            guard let tbr = format.tbr, tbr > 0, let duration, duration > 0, duration.isFinite else { return nil }
            return Int64((tbr * 1000 / 8 * duration).rounded())
        }
    }

    /// `ba` prefers audio-only tracks; muxed formats only matter when nothing better exists.
    /// Ranking mirrors `audioSort`: AAC/m4a first (also skips an opus→m4a transcode), then the
    /// largest size-known track — unknown-size premium duplicates rank last, exactly like `-S`.
    static func bestAudioFormat(in formats: [SizedFormat], duration: Double?) -> SizedFormat? {
        let plain = formats.filter { !($0.format.note?.localizedCaseInsensitiveContains("DRC") ?? false) }
        let pool = plain.isEmpty ? formats : plain
        return pool.min { a, b in
            audioRank(a) < audioRank(b)
        }
    }

    private static func audioRank(_ format: SizedFormat) -> (Int, Int, Int64, Double) {
        let ext = (format.format.ext ?? "").lowercased()
        return (ext == "m4a" || ext == "mp4" ? 0 : 1,
                format.known == nil ? 1 : 0,
                format.known ?? 0,
                format.format.tbr ?? 0)
    }

    /// Mirrors the video half of the sort specs: H.264 (when preferred) → muxed/AAC →
    /// largest size-known format → higher bitrate.
    private static func pickVideoFormat(_ candidates: [SizedFormat], preferH264: Bool) -> SizedFormat? {
        candidates.min { a, b in
            rank(a, preferH264: preferH264) < rank(b, preferH264: preferH264)
        }
    }

    private static func rank(_ format: SizedFormat, preferH264: Bool) -> (Int, Int, Int, Int64, Double) {
        let codec = preferH264 && format.format.codecName == "H.264" ? 0 : 1
        let audio = preferH264 && format.format.hasAudio ? 0 : 1   // `acodec:aac` in quickTimeSort favours muxed
        return (codec, audio, format.known == nil ? 1 : 0, format.known ?? 0, format.format.tbr ?? 0)
    }

    private static func sum(_ a: Int64?, _ b: Int64?) -> Int64? {
        switch (a, b) {
        case let (a?, b?): return a + b
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }
}
