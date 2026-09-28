import Foundation

/// Wildcard site exceptions like `*.apple.com` or `cdn.example.com` (spec §6.6 İstisnalar).
/// Shared meaning: a leading `*.` covers the domain and every subdomain; a bare domain
/// matches itself and its subdomains; a pattern containing `*` elsewhere matches literally
/// with `*` as any suffix of that label.
public struct SiteExceptions: Equatable, Sendable {
    public var patterns: [String]

    public init(_ patterns: [String] = []) {
        self.patterns = patterns.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    public func matches(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return matches(host: host)
    }

    public func matches(host: String) -> Bool {
        for pattern in patterns {
            if pattern.hasPrefix("*.") {
                let domain = String(pattern.dropFirst(2))
                if host == domain || host.hasSuffix("." + domain) { return true }
            } else if pattern.hasSuffix(".*") {
                // `example.*` — any TLD
                let base = String(pattern.dropLast(2))
                if host == base || (host.hasPrefix(base + ".") && !host.dropFirst(base.count + 1).contains(".")) { return true }
            } else if pattern.contains("*") {
                // Generic glob within one label, e.g. `cdn-*.example.com`
                if glob(pattern, matches: host) { return true }
            } else if host == pattern || host.hasSuffix("." + pattern) {
                return true
            }
        }
        return false
    }

    private func glob(_ pattern: String, matches host: String) -> Bool {
        // Both are split into labels so `*` never crosses a dot boundary.
        let patternParts = pattern.split(separator: ".", omittingEmptySubsequences: false)
        let hostParts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard patternParts.count == hostParts.count else { return false }
        for (patternPart, hostPart) in zip(patternParts, hostParts) {
            guard labelGlob(patternPart, matches: hostPart) else { return false }
        }
        return true
    }

    private func labelGlob(_ pattern: some StringProtocol, matches text: some StringProtocol) -> Bool {
        let pattern = Array(pattern), text = Array(text)
        var p = 0, t = 0, star = -1, mark = 0
        while t < text.count {
            if p < pattern.count, pattern[p] == "*" {
                star = p
                p += 1
                mark = t
            } else if p < pattern.count, pattern[p] == text[t] {
                p += 1
                t += 1
            } else if star >= 0 {
                p = star + 1
                mark += 1
                t = mark
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }
}
