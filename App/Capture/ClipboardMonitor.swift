import AppKit

/// Polls the pasteboard once a second (spec §6.5). On macOS 15.4+ it first asks the system whether a
/// web URL is present, without reading the contents, so no privacy alert appears for ordinary copies.
@MainActor
final class ClipboardMonitor {
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var lastURL: URL?
    private let isEnabled: () -> Bool
    private let shouldCapture: (URL) -> Bool
    private let onURL: (URL) -> Void

    init(isEnabled: @escaping () -> Bool, shouldCapture: @escaping (URL) -> Bool, onURL: @escaping (URL) -> Void) {
        self.isEnabled = isEnabled
        self.shouldCapture = shouldCapture
        self.onURL = onURL
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard isEnabled(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        if #available(macOS 15.4, *) {
            let changeCount = lastChangeCount
            // Detection runs off the main actor; NSPasteboard is not Sendable, so each side uses `.general`.
            Task.detached { [weak self] in
                let patterns = try? await NSPasteboard.general.detectedPatterns(for: [\.probableWebURL])
                guard patterns?.contains(\.probableWebURL) == true else { return }
                await self?.readURL(ifUnchangedSince: changeCount)
            }
        } else {
            readURL(ifUnchangedSince: lastChangeCount)
        }
    }

    private func readURL(ifUnchangedSince changeCount: Int) {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == changeCount,
              let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.contains(where: \.isWhitespace), let url = URL(string: text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url != lastURL, shouldCapture(url) else { return }
        lastURL = url
        onURL(url)
    }
}
