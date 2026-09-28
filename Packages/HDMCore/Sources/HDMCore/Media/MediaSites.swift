import Foundation

/// Cheap heuristic: is this URL a video page worth a yt-dlp query?
/// Used to decide whether a clipboard link should open the quality dialog; URLs typed into
/// "Add URL" are always probed, so this list only needs to cover popular sites (spec §6.5).
public enum MediaSites {
    static let domains: Set<String> = [
        "youtube.com", "youtu.be", "vimeo.com", "dailymotion.com", "dai.ly",
        "tiktok.com", "instagram.com", "twitter.com", "x.com",
        "twitch.tv", "soundcloud.com", "facebook.com", "fb.watch",
        "bilibili.com", "b23.tv", "reddit.com", "v.redd.it", "streamable.com",
        "odysee.com", "rumble.com", "nicovideo.jp", "bandcamp.com", "mixcloud.com",
        "vk.com", "ok.ru", "pinterest.com", "threads.net",
    ]

    /// Direct stream manifests that the HTTP engine cannot handle; these always go to yt-dlp.
    public static let streamExtensions: Set<String> = ["m3u8", "mpd"]

    public static func isKnownVideoSite(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        var labels = host.split(separator: ".").map(String.init)
        for domain in domains {
            if host == domain { return true }
            if host.hasSuffix("." + domain) {
                // www., m., music., player. … subdomains of a listed domain
                labels.removeLast(domain.split(separator: ".").count)
                if labels.allSatisfy({ $0.count <= 8 }), labels.count <= 2 { return true }
            }
        }
        return false
    }
}
