import Foundation

public enum MediaEvent: Sendable, Equatable {
    /// Cumulative across all formats of the job (yt-dlp reports progress per format).
    case progress(receivedBytes: Int64, totalBytes: Int64?)
    case postProcessing
    case finished(path: URL?, totalBytes: Int64)
    case failed(FailureReason)
}

/// Drives one yt-dlp download process (spec §8.3). Pause sends SIGINT; yt-dlp keeps its `.part`
/// files, and a fresh run with the same request resumes from them. Arguments come from `MediaPlan`.
public actor MediaEngine {
    private enum State { case idle, running, stopping, finished }
    private enum PipeLine: Sendable { case out(String), err(String) }

    /// Reads one pipe and hands complete lines to a callback. The buffer is lock-protected because
    /// `readabilityHandler` runs on an arbitrary queue.
    private final class LineSource: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private let deliver: @Sendable (String) -> Void

        init(pipe: Pipe, deliver: @escaping @Sendable (String) -> Void) {
            self.deliver = deliver
            let handle = pipe.fileHandleForReading
            handle.readabilityHandler = { [weak self] _ in
                guard let self else {
                    handle.readabilityHandler = nil
                    return
                }
                self.receive(handle.availableData)
            }
        }

        private func receive(_ chunk: Data) {
            lock.lock()
            if !chunk.isEmpty { buffer.append(chunk) }
            var lines: [String] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                if let line = String(data: lineData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespaces), !line.isEmpty {
                    lines.append(line)
                }
            }
            if chunk.isEmpty, !buffer.isEmpty {   // EOF: flush a final line without a newline
                if let line = String(data: buffer, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespaces), !line.isEmpty {
                    lines.append(line)
                }
                buffer.removeAll()
            }
            if buffer.count > 1 << 20 { buffer.removeAll() }   // runaway line without a terminator
            lock.unlock()
            lines.forEach(deliver)
        }
    }

    public nonisolated let events: AsyncStream<MediaEvent>
    private let continuation: AsyncStream<MediaEvent>.Continuation
    private let request: MediaRequest

    private var state = State.idle
    private var process: Process?
    private var lineSources: [LineSource] = []
    private var lineContinuation: AsyncStream<PipeLine>.Continuation?
    private var interrupted = false
    private var exitStatus: (code: Int32, reason: Process.TerminationReason)?
    private var exitLatch: CheckedContinuation<Void, Never>?
    private var finalPath: URL?
    private var lastError: String?
    private var lastLineFinalPath: URL?
    // Progress bookkeeping across the sequential per-format downloads of one job.
    private var completedFormatBytes: Int64 = 0
    private var lastFormatDownloaded: Int64 = 0
    private var sawFormatBoundary = false
    private var emittedReceived: Int64 = 0

    public init(request: MediaRequest) {
        self.request = request
        (events, continuation) = AsyncStream.makeStream(of: MediaEvent.self, bufferingPolicy: .unbounded)
    }

    public func start() {
        guard state == .idle else { return }
        state = .running
        guard let binary = request.tools.ytDLP else {
            finish(with: .failed(.media("yt-dlp could not be found. Install it with: brew install yt-dlp")))
            return
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = MediaPlan.arguments(for: request)
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let lines = AsyncStream<PipeLine>.makeStream(of: PipeLine.self, bufferingPolicy: .unbounded)
        lineContinuation = lines.continuation
        lineSources = [
            LineSource(pipe: stdout) { [continuation = lines.continuation] in continuation.yield(.out($0)) },
            LineSource(pipe: stderr) { [continuation = lines.continuation] in continuation.yield(.err($0)) },
        ]
        do {
            try FileManager.default.createDirectory(at: request.directory, withIntermediateDirectories: true)
            try process.run()
        } catch {
            finish(with: .failed(.fileSystem(error.localizedDescription)))
            return
        }
        self.process = process
        Task { await self.monitor(process, lines: lines.stream) }
    }

    /// Pause: SIGINT, then wait for yt-dlp to flush its `.part` files and exit.
    public func pause() async {
        guard state == .running else { return }
        state = .stopping
        interrupted = true
        process?.interrupt()
        await exitBarrier()
    }

    /// Cancel: SIGTERM, escalating to SIGKILL after a grace period. Waits for the process to die.
    public func cancel() async {
        guard state == .running || state == .stopping else { return }
        state = .stopping
        interrupted = true
        if let process, process.isRunning { process.terminate() }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        await exitBarrier()
    }

    // MARK: - Internals

    private func monitor(_ process: Process, lines: AsyncStream<PipeLine>) async {
        DispatchQueue.global().async { [weak self] in
            process.waitUntilExit()
            guard let self else { return }
            Task { await self.processExited(code: process.terminationStatus, reason: process.terminationReason) }
        }
        for await line in lines { consume(line) }
        // The stream only finishes after `processExited` recorded the exit status, so every line
        // has been consumed here before the outcome below is decided.
        guard let exit = exitStatus, state != .finished else { return }
        if interrupted {
            finish(with: nil)   // manager-initiated pause/cancel; it records the status itself
        } else if exit.reason == .uncaughtSignal {
            finish(with: .failed(.media("yt-dlp was killed (signal \(exit.code))")))
        } else if exit.code == 0 {
            let path = finalPath ?? lastLineFinalPath ?? Self.searchFinalFile(request: request)
            finish(with: .finished(path: path, totalBytes: max(emittedReceived, 0)))
        } else {
            finish(with: .failed(.media(Self.cleanError(lastError) ?? "yt-dlp exited with status \(exit.code)")))
        }
    }

    private func processExited(code: Int32, reason: Process.TerminationReason) {
        guard exitStatus == nil else { return }
        exitStatus = (code, reason)
        lineContinuation?.finish()
        lineContinuation = nil
    }

    private func consume(_ line: PipeLine) {
        guard state == .running || state == .stopping else { return }
        switch line {
        case .err(let text):
            lastError = text
        case .out(let text):
            consumeStdout(text)
        }
    }

    private func consumeStdout(_ line: String) {
        if ProgressParser.isPostProcessing(line) {
            finalPath = finalPath ?? ProgressParser.finalPathHint(line)
            if state == .running { continuation.yield(.postProcessing) }
            return
        }
        if let hint = ProgressParser.finalPathHint(line) {
            lastLineFinalPath = hint
            if line.contains("has already been downloaded") { finalPath = hint }
        }
        guard let progress = ProgressParser.progress(line) else { return }
        // yt-dlp downloads formats one after another; a shrinking byte count means the next format
        // started. Fold the finished one into `completedFormatBytes` so overall progress is monotonic.
        if progress.downloadedBytes < lastFormatDownloaded, lastFormatDownloaded > 0 {
            completedFormatBytes += lastFormatDownloaded
            sawFormatBoundary = true
        }
        lastFormatDownloaded = progress.downloadedBytes
        let received = completedFormatBytes + progress.downloadedBytes
        let total: Int64?
        if let approx = request.approxTotalBytes, approx > 0 {
            total = approx
        } else if sawFormatBoundary {
            total = nil   // more formats may follow and per-format totals would mislead
        } else {
            total = progress.totalBytes
        }
        emittedReceived = received
        if state == .running { continuation.yield(.progress(receivedBytes: received, totalBytes: total)) }
    }

    private func finish(with event: MediaEvent?) {
        guard state != .finished else { return }
        state = .finished
        if let event { continuation.yield(event) }
        continuation.finish()
        exitLatch?.resume()
        exitLatch = nil
    }

    private func exitBarrier() async {
        if state == .finished { return }
        await withCheckedContinuation { exitLatch = $0 }
    }

    /// When `--print after_move:filepath` output was missed, look for the file ourselves:
    /// newest `base.*` file in the target directory with a media extension.
    static func searchFinalFile(request: MediaRequest) -> URL? {
        let fm = FileManager.default
        let extensions: Set<String> = ["mp4", "m4a", "mkv", "webm", "mp3", "opus", "flac", "wav", "mov"]
        guard let entries = try? fm.contentsOfDirectory(at: request.directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var best: (url: URL, date: Date)?
        for entry in entries where entry.lastPathComponent.hasPrefix(request.baseName + ".")
                && extensions.contains(entry.pathExtension.lowercased()) {
            let date = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if best == nil || date > best!.date { best = (entry, date) }
        }
        return best?.url
    }

    private static func cleanError(_ message: String?) -> String? {
        guard var message else { return nil }
        for prefix in ["ERROR: ", "WARNING: "] where message.hasPrefix(prefix) {
            message = String(message.dropFirst(prefix.count))
        }
        return message.isEmpty ? nil : message
    }
}
