import Foundation

public enum DownloadCategory: String, Codable, CaseIterable, Sendable, Identifiable, CodingKeyRepresentable {
    case compressed, documents, music, programs, video, general

    public var id: String { rawValue }

    /// Folder names are not localised so paths never change with the UI language.
    public var folderName: String {
        switch self {
        case .compressed: "Compressed"
        case .documents: "Documents"
        case .music: "Music"
        case .programs: "Programs"
        case .video: "Video"
        case .general: "General"
        }
    }

    public static let defaultExtensions: [DownloadCategory: [String]] = [
        .compressed: ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "tgz", "iso"],
        .documents: ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "txt", "rtf", "epub", "csv"],
        .music: ["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "wma"],
        .programs: ["dmg", "pkg", "app", "exe", "msi", "apk", "deb", "rpm", "appimage"],
        .video: ["mp4", "mkv", "webm", "mov", "avi", "m4v", "flv", "wmv", "ts", "3gp"],
        .general: [],
    ]
}

public struct CategoryResolver: Sendable {
    public var extensions: [DownloadCategory: [String]]

    public init(extensions: [DownloadCategory: [String]] = DownloadCategory.defaultExtensions) {
        self.extensions = extensions
    }

    /// First category in `allCases` order that lists the extension wins.
    public func category(forFileName name: String) -> DownloadCategory {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return .general }
        for category in DownloadCategory.allCases where category != .general {
            if extensions[category]?.contains(ext) == true { return category }
        }
        return .general
    }
}
