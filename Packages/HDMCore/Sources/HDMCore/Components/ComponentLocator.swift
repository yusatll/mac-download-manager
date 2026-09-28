import Foundation

/// Paths of the external tools HDM drives (spec §9). `nil` means the tool was not found.
public struct ComponentPaths: Sendable, Equatable {
    public var ytDLP: URL?
    public var ffmpeg: URL?
    public var deno: URL?

    public init(ytDLP: URL? = nil, ffmpeg: URL? = nil, deno: URL? = nil) {
        self.ytDLP = ytDLP
        self.ffmpeg = ffmpeg
        self.deno = deno
    }
}

public struct ComponentStatus: Sendable, Equatable, Identifiable {
    public var name: String
    public var path: URL?
    public var version: String?
    public var variant: Variant

    public enum Variant: String, Sendable { case ytDLP = "yt-dlp", ffmpeg, deno }

    public var id: String { name }
    public var found: Bool { path != nil }

    public init(variant: Variant, path: URL?, version: String?) {
        self.name = variant.rawValue
        self.path = path
        self.version = version
        self.variant = variant
    }
}

/// Finds yt-dlp, ffmpeg and deno: first the copy HDM installed itself (spec §9),
/// then the Homebrew prefixes, then whatever `PATH` offers.
public enum ComponentLocator {
    public static let appBinDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MacDM/bin", isDirectory: true)

    public static func locate() -> ComponentPaths {
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let brewPrefixes = [URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin")]
        return locate(appBin: appBinDirectory, extraDirectories: brewPrefixes, pathEnv: pathEnv)
    }

    /// Split for tests: the search order is `appBin`, `extraDirectories` in order, then each
    /// `PATH` entry in order. First executable file wins.
    public static func locate(appBin: URL, extraDirectories: [URL], pathEnv: String) -> ComponentPaths {
        let search = [appBin] + extraDirectories + pathEnv.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        return ComponentPaths(
            ytDLP: findTool("yt-dlp", in: search),
            ffmpeg: findTool("ffmpeg", in: search),
            deno: findTool("deno", in: search))
    }

    /// Runs `<tool> --version` for each tool; missing tools report no path or version.
    public static func status() async -> [ComponentStatus] {
        let paths = locate()
        let ytDLPVersion = await version(of: paths.ytDLP)
        let ffmpegVersion = await version(of: paths.ffmpeg)
        let denoVersion = await version(of: paths.deno)
        return [
            ComponentStatus(variant: .ytDLP, path: paths.ytDLP, version: ytDLPVersion),
            ComponentStatus(variant: .ffmpeg, path: paths.ffmpeg, version: ffmpegVersion),
            ComponentStatus(variant: .deno, path: paths.deno, version: denoVersion),
        ]
    }

    static func findTool(_ name: String, in directories: [URL]) -> URL? {
        let fm = FileManager.default
        for directory in directories {
            let candidate = directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue,
               fm.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// `<binary> --version`, first line only; nil when the tool is missing or fails.
    static func version(of url: URL?) async -> String? {
        guard let url else { return nil }
        return await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = url
            process.arguments = ["--version"]
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return nil }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)?
                .split(whereSeparator: \.isNewline).first.map(String.init)
        }.value
    }
}
