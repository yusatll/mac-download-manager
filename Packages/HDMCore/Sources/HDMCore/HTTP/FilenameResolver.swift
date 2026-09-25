import Foundation
import UniformTypeIdentifiers

/// Chooses and cleans the on-disk file name (spec §5.6).
public enum FilenameResolver {
    public static func resolve(userProvided: String? = nil, contentDisposition: String? = nil,
                               suggested: String? = nil, url: URL, mimeType: String? = nil) -> String {
        if let user = userProvided?.trimmingCharacters(in: .whitespacesAndNewlines), !user.isEmpty {
            return sanitize(user)
        }
        if let header = contentDisposition, let name = parseContentDisposition(header), !name.isEmpty {
            return sanitize(name)
        }
        if let suggested = suggested?.trimmingCharacters(in: .whitespacesAndNewlines), !suggested.isEmpty {
            return sanitize(suggested)
        }
        let last = url.lastPathComponent
        var name = (last.isEmpty || last == "/") ? "index" : last
        if (name as NSString).pathExtension.isEmpty, let ext = fileExtension(forMIMEType: mimeType) {
            name += "." + ext
        }
        return sanitize(name)
    }

    public static func parseContentDisposition(_ header: String) -> String? {
        var params: [String: String] = [:]
        for part in splitParameters(header).dropFirst() {
            guard let eq = part.firstIndex(of: "=") else { continue }
            let key = part[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
            }
            params[key] = value
        }
        if let extended = params["filename*"], let marker = extended.range(of: "''"),
           let decoded = extended[marker.upperBound...].removingPercentEncoding, !decoded.isEmpty {
            return decoded
        }
        if let plain = params["filename"], !plain.isEmpty {
            return plain.removingPercentEncoding ?? plain
        }
        return nil
    }

    public static func sanitize(_ name: String) -> String {
        var s = String(String.UnicodeScalarView(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        for bad in ["/", ":", "\\"] { s = s.replacingOccurrences(of: bad, with: "_") }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.isEmpty { s = "download" }
        if s.utf8.count > 255 {
            let ext = (s as NSString).pathExtension
            var base = (s as NSString).deletingPathExtension
            let limit = 255 - (ext.isEmpty ? 0 : ext.utf8.count + 1)
            while base.utf8.count > limit { base.removeLast() }
            s = ext.isEmpty ? base : base + "." + ext
        }
        return s
    }

    /// `name`, or `name (2)`, `name (3)` … whichever has neither a file nor a `.hdmpart` in `directory`.
    public static func uniqueName(_ name: String, in directory: URL) -> String {
        let fm = FileManager.default
        func taken(_ candidate: String) -> Bool {
            let path = directory.appendingPathComponent(candidate).path
            return fm.fileExists(atPath: path) || fm.fileExists(atPath: path + ".hdmpart")
        }
        guard taken(name) else { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            if !taken(candidate) { return candidate }
            n += 1
        }
    }

    private static func fileExtension(forMIMEType mime: String?) -> String? {
        guard let mime, !mime.hasPrefix("application/octet-stream"), let type = UTType(mimeType: mime) else { return nil }
        return type.preferredFilenameExtension
    }

    private static func splitParameters(_ header: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for ch in header {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" && inQuotes { current.append(ch); escaped = true; continue }
            if ch == "\"" { inQuotes.toggle() }
            if ch == ";" && !inQuotes { parts.append(current); current = "" } else { current.append(ch) }
        }
        parts.append(current)
        return parts
    }
}
