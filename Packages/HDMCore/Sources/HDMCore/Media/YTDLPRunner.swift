import Foundation

public enum MediaQueryError: Error, Equatable, Sendable {
    case ytDLPNotFound
    /// The page is not a video site yt-dlp supports — fall back to a regular HTTP download.
    case unsupportedURL
    case timedOut
    case failed(String)
}

/// Asks yt-dlp what a page contains: `yt-dlp -J --no-playlist` (spec §8.3), or a fast
/// `--flat-playlist` listing when the URL is a playlist.
public enum YTDLPRunner {
    public static func query(pageURL: URL, headers: [String: String] = [:],
                             tools: ComponentPaths, timeout: TimeInterval = 30,
                             flatPlaylist: Bool = false) async throws -> YTDLPInfo {
        guard let binary = tools.ytDLP else { throw MediaQueryError.ytDLPNotFound }
        let process = Process()
        process.executableURL = binary
        var arguments = ["-J", "--no-update", "--no-warnings"]
        arguments.append(flatPlaylist ? "--flat-playlist" : "--no-playlist")
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            arguments += ["--add-header", "\(name): \(value)"]
        }
        arguments.append(pageURL.absoluteString)
        process.arguments = arguments
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do { try process.run() } catch { throw MediaQueryError.failed(error.localizedDescription) }

        let result: Result<Data, Error> = await withTaskGroup(of: Result<Data, Error>.self) { group in
            group.addTask {
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                let errorText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                process.waitUntilExit()
                if process.terminationStatus == 0, !data.isEmpty {
                    return .success(data)
                }
                if process.terminationReason == .uncaughtSignal {
                    return .failure(MediaQueryError.timedOut)
                }
                return .failure(Self.mapFailure(exitCode: process.terminationStatus, stderr: errorText))
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if process.isRunning { process.terminate() }
                return .failure(MediaQueryError.timedOut)
            }
            let first = await group.next() ?? .failure(MediaQueryError.timedOut)
            group.cancelAll()
            return first
        }

        switch result {
        case .success(let data):
            do {
                return try JSONDecoder().decode(YTDLPInfo.self, from: data)
            } catch {
                throw MediaQueryError.failed("yt-dlp returned unreadable metadata: \(error.localizedDescription)")
            }
        case .failure(let error):
            throw error
        }
    }

    private static func mapFailure(exitCode: Int32, stderr: String) -> MediaQueryError {
        let last = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        if last.contains("Unsupported URL") || last.contains("is not a valid URL") {
            return .unsupportedURL
        }
        let message = last.hasPrefix("ERROR: ") ? String(last.dropFirst(7)) : last
        return .failed(message.isEmpty ? "yt-dlp exited with status \(exitCode)" : message)
    }
}
