import Foundation

/// What the browser knows about a page's video (spec §8.1): the page itself, embedded player
/// pages and the media URLs it has seen being loaded.
public struct MediaHints: Sendable, Equatable {
    public struct Stream: Sendable, Equatable {
        public enum Kind: String, Sendable { case file, hls, dash }
        public var url: URL
        public var kind: Kind
        /// The frame that loaded the stream; players often check it as Referer/Origin.
        public var frameURL: URL?

        public init(url: URL, kind: Kind, frameURL: URL? = nil) {
            self.url = url
            self.kind = kind
            self.frameURL = frameURL
        }
    }

    public var pageURL: URL
    public var embeds: [URL]
    public var streams: [Stream]

    public init(pageURL: URL, embeds: [URL] = [], streams: [Stream] = []) {
        self.pageURL = pageURL
        self.embeds = embeds
        self.streams = streams
    }
}

/// One URL to hand to yt-dlp, with the headers it should be fetched with.
public struct MediaCandidate: Sendable, Equatable {
    public var url: URL
    public var headers: [String: String]
}

public struct ResolvedMedia: Sendable, Equatable {
    public var candidate: MediaCandidate
    public var info: YTDLPInfo
}

/// Finds a video yt-dlp can download (spec §8.3): the page first, then embedded players, then the
/// HLS/DASH streams the browser saw. Every candidate is tried; the most useful failure is reported.
public enum MediaResolver {
    /// Tried in order. Direct files are not candidates: they go to the HTTP engine.
    public static func candidates(for hints: MediaHints, headers: [String: String]) -> [MediaCandidate] {
        var list: [MediaCandidate] = [MediaCandidate(url: hints.pageURL, headers: headers)]
        for embed in hints.embeds where embed != hints.pageURL {
            list.append(MediaCandidate(url: embed, headers: headers.merging(referrer(hints.pageURL)) { $1 }))
        }
        let adaptive = hints.streams.filter { $0.kind == .hls } + hints.streams.filter { $0.kind == .dash }
        for stream in adaptive {
            let from = stream.frameURL ?? hints.pageURL
            list.append(MediaCandidate(url: stream.url, headers: headers.merging(referrer(from)) { $1 }))
        }
        var seen = Set<URL>()
        return list.filter { seen.insert($0.url).inserted }
    }

    public static func resolve(_ candidates: [MediaCandidate],
                               using query: @Sendable (MediaCandidate) async throws -> YTDLPInfo) async
        -> Result<ResolvedMedia, MediaQueryError> {
        var best: MediaQueryError = .unsupportedURL
        for candidate in candidates {
            do {
                return .success(ResolvedMedia(candidate: candidate, info: try await query(candidate)))
            } catch {
                let failure = (error as? MediaQueryError) ?? .failed(error.localizedDescription)
                if rank(failure) > rank(best) { best = failure }
                if failure == .ytDLPNotFound { break }
            }
        }
        return .failure(best)
    }

    /// yt-dlp's title unless it is really a storage path or file name (Wistia does this); then the page title.
    public static func displayTitle(ytDLPTitle: String, pageTitle: String?) -> String {
        let page = pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let looksLikeFile = ytDLPTitle.contains("/")
            || ["mp4", "mov", "m4v", "webm", "mkv", "mp3", "m4a"].contains((ytDLPTitle as NSString).pathExtension.lowercased())
        return looksLikeFile && !page.isEmpty ? page : ytDLPTitle
    }

    private static func referrer(_ url: URL) -> [String: String] {
        var headers = ["Referer": url.absoluteString]
        if let scheme = url.scheme, let host = url.host() {
            headers["Origin"] = "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
        }
        return headers
    }

    /// A concrete yt-dlp error tells the user more than "unsupported"; a missing yt-dlp most of all.
    private static func rank(_ error: MediaQueryError) -> Int {
        switch error {
        case .unsupportedURL: 0
        case .timedOut: 1
        case .failed: 2
        case .ytDLPNotFound: 3
        }
    }
}
