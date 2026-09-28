import Foundation

/// Turns a parsed `yt-dlp -J` result into the quality list shown to the user (spec §8.3).
/// One row per available height, best option first, plus an "Audio only" row.
public enum FormatMapper {
    /// `-S` sort spec that prefers H.264 + AAC when available ("QuickTime compatible", default on).
    public static let quickTimeSort = "res,vcodec:h264,acodec:aac"

    public static func videoInfo(from info: YTDLPInfo, preferQuickTimeCompatible: Bool = true) -> VideoInfo {
        VideoInfo(title: info.title ?? "video",
                  duration: info.duration,
                  uploader: info.uploader,
                  options: options(from: info, preferQuickTimeCompatible: preferQuickTimeCompatible),
                  isLive: info.isLive)
    }

    public static func options(from info: YTDLPInfo, preferQuickTimeCompatible: Bool = true) -> [MediaFormatOption] {
        let formats = info.allFormats
        let sort = preferQuickTimeCompatible ? quickTimeSort : nil
        var rows: [MediaFormatOption] = []

        let videoFormats = formats.filter { $0.hasVideo && $0.height != nil }
        // `ba` prefers audio-only tracks; muxed formats only matter when nothing better exists.
        let bestAudio = bestAudioFormat(in: formats.filter { $0.hasAudio && !$0.hasVideo })
            ?? bestAudioFormat(in: formats.filter { $0.hasAudio })

        // One row per height, highest first. The selector's fallback branch covers muxed-only sources,
        // so it works whether the site offers adaptive (merge) or muxed (single file) formats.
        let heights = Set(videoFormats.compactMap(\.height)).sorted(by: >)
        for height in heights {
            let candidates = videoFormats.filter { $0.height == height }
            let chosen = pickVideoFormat(candidates, preferH264: preferQuickTimeCompatible) ?? candidates[0]
            let selector = "bv*[height<=\(height)]+ba/b[height<=\(height)]"
            // Estimate = best video at this height + best audio (merged), or the muxed size itself.
            let videoSize = (chosen.hasAudio ? nil : chosen.knownSize)
                ?? pickVideoFormat(candidates.filter { !$0.hasAudio }, preferH264: preferQuickTimeCompatible)?.knownSize
                ?? chosen.knownSize
            let audioSize = chosen.hasAudio ? nil : bestAudio?.knownSize
            let approxSize = sum(videoSize, audioSize) ?? chosen.knownSize

            var note: String?
            if let codec = chosen.codecName, codec != "H.264" {
                let h264Available = candidates.contains { $0.codecName == "H.264" }
                if !h264Available { note = "\(codec) — VLC/IINA recommended" }
            }
            rows.append(MediaFormatOption(label: "\(height)p", selector: selector, sortSpec: sort, ext: "MP4",
                                          approxSize: approxSize, note: note, audioOnly: false, height: height))
        }

        if let audio = bestAudio {
            rows.append(MediaFormatOption(label: "Audio only", selector: "ba/b", sortSpec: nil, ext: "M4A",
                                          approxSize: audio.knownSize, note: nil, audioOnly: true, height: nil))
        }

        // A single muxed-only source (e.g. a direct .mp4) still yields one usable row.
        if rows.isEmpty, let only = formats.first {
            rows.append(MediaFormatOption(label: only.height.map { "\($0)p" } ?? "Original", selector: "b", sortSpec: nil,
                                          ext: (only.ext ?? "mp4").uppercased(), approxSize: only.knownSize,
                                          note: nil, audioOnly: !only.hasVideo, height: only.height))
        }
        return rows
    }

    /// The audio row's size: prefer AAC/m4a (matches `-x --audio-format m4a`), then best bitrate.
    static func bestAudioFormat(in formats: [YTDLPInfo.Format]) -> YTDLPInfo.Format? {
        formats.filter { !($0.note?.localizedCaseInsensitiveContains("DRC") ?? false) }.max { a, b in
            rank(a) < rank(b)
        } ?? formats.max { rank($0) < rank($1) }
    }

    private static func rank(_ format: YTDLPInfo.Format) -> Double {
        let codecBonus: Double
        switch (format.ext ?? "").lowercased() {
        case "m4a", "mp4": codecBonus = 100_000
        default: codecBonus = 0
        }
        return (format.tbr ?? 0) + codecBonus
    }

    private static func pickVideoFormat(_ candidates: [YTDLPInfo.Format], preferH264: Bool) -> YTDLPInfo.Format? {
        candidates.max { a, b in
            quality(a, preferH264: preferH264) < quality(b, preferH264: preferH264)
        }
    }

    private static func quality(_ format: YTDLPInfo.Format, preferH264: Bool) -> Double {
        var score = format.tbr ?? 0
        if preferH264, format.codecName == "H.264" { score += 1_000_000 }
        if format.hasAudio { score += 500_000 }
        return score
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
