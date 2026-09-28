import Foundation

/// Writes `com.hizdm.bridge.json` into every installed Chromium browser's NativeMessagingHosts
/// directory on launch (spec §7.2). `path` always points at this bundle's copy of the bridge,
/// so a moved app repairs itself on the next launch.
enum NativeMessagingManifest {
    static let hostName = "com.hizdm.bridge"

    /// Fixed extension ID derived from the `key` in the extension manifest — stable across
    /// installs ("Load unpacked" included). The Web Store ID is appended once published.
    static let allowedOrigins = ["chrome-extension://fiomonmfcioeoiaigikcmlajedejcbbg/"]

    static let browserDirectories = [
        "Google/Chrome/NativeMessagingHosts",
        "Google/Chrome Beta/NativeMessagingHosts",
        "Google/Chrome Canary/NativeMessagingHosts",
        "Chromium/NativeMessagingHosts",
        "BraveSoftware/Brave-Browser/NativeMessagingHosts",
        "Microsoft Edge/NativeMessagingHosts",
        "Vivaldi/NativeMessagingHosts",
    ]

    static func writeAll(bundleURL: URL = Bundle.main.bundleURL) {
        let helper = bundleURL.appendingPathComponent("Contents/Helpers/hdm-bridge", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            NSLog("HDM: hdm-bridge is missing from the app bundle; native messaging stays unregistered")
            return
        }
        let manifest: [String: Any] = [
            "name": hostName,
            "description": "Hiz Download Manager",
            "path": helper.path,
            "type": "stdio",
            "allowed_origins": allowedOrigins,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) else { return }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for directory in browserDirectories {
            let target = support.appendingPathComponent(directory, isDirectory: true)
                .appendingPathComponent("\(hostName).json", isDirectory: false)
            // Only browsers that exist get a manifest; stale paths point at the new bundle location.
            guard FileManager.default.fileExists(atPath: target.path)
                    || FileManager.default.fileExists(atPath: support.appendingPathComponent(directory).deletingLastPathComponent().path)
                    || ["Google/Chrome/NativeMessagingHosts", "BraveSoftware/Brave-Browser/NativeMessagingHosts"].contains(directory) else { continue }
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: target, options: .atomic)
        }
    }
}
