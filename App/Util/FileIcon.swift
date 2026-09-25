import AppKit
import UniformTypeIdentifiers

@MainActor
enum FileIcon {
    private static var cache: [String: NSImage] = [:]

    static func icon(for fileName: String) -> NSImage {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if let cached = cache[ext] { return cached }
        let image = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        cache[ext] = image
        return image
    }
}
