import Foundation
import HDMCore

extension DownloadCategory {
    var title: String {
        switch self {
        case .compressed: String(localized: "Compressed")
        case .documents: String(localized: "Documents")
        case .music: String(localized: "Music")
        case .programs: String(localized: "Programs")
        case .video: String(localized: "Video")
        case .general: String(localized: "General")
        }
    }

    var symbol: String {
        switch self {
        case .compressed: "doc.zipper"
        case .documents: "doc.text"
        case .music: "music.note"
        case .programs: "app.badge"
        case .video: "film"
        case .general: "doc"
        }
    }
}

extension DownloadStatus {
    func text(fraction: Double?) -> String {
        switch self {
        case .queued: String(localized: "Queued")
        case .connecting: String(localized: "Connecting…")
        case .downloading: fraction.map { Format.percent($0) } ?? String(localized: "Downloading")
        case .paused: fraction.map { String(localized: "Paused (\(Format.percent($0)))") } ?? String(localized: "Paused")
        case .merging: String(localized: "Merging…")
        case .completed: String(localized: "Complete")
        case .failed: String(localized: "Error")
        case .needsRefresh: String(localized: "Link expired")
        }
    }
}

extension FailureReason {
    var message: String {
        switch self {
        case .network(let detail): String(localized: "Network error: \(detail)")
        case .http(let code): String(localized: "Server returned HTTP \(code).")
        case .authRequired: String(localized: "The server requires a user name and password.")
        case .serverFileChanged: String(localized: "The file on the server has changed. Restart the download.")
        case .diskFull: String(localized: "There is not enough disk space.")
        case .fileSystem(let detail): String(localized: "File error: \(detail)")
        case .media(let detail): String(localized: "Video download error: \(detail)")
        }
    }
}
