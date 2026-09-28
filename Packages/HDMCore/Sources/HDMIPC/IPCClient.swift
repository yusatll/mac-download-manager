import Foundation

#if canImport(Darwin)
import Darwin

enum SocketError {
    static func last() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
    }
}

/// Connects to the app's socket, sends one framed request and reads one framed reply.
/// Used by `hdm-bridge` and by tests.
public enum IPCClient {
    /// - Parameters:
    ///   - launchApp: called when no socket exists; should start HDM in the background.
    ///   - preprocess: test hook that rewrites the wire frame after encoding.
    public static func request(_ message: IPCMessage, timeout: TimeInterval = 10,
                               socketURL: URL = IPCProtocol.socketPath(),
                               launchApp: (() -> Void)? = nil,
                               preprocess: ((Data) -> Data)? = nil) async throws -> IPCResponse {
        var didLaunch = false
        let deadline = Date().addingTimeInterval(timeout)
        let connection: Connection
        while true {
            if let opened = Connection(socketURL: socketURL) {
                connection = opened
                break
            }
            if !didLaunch, let launchApp {
                launchApp()   // one nudge, then keep polling until the deadline (spec §7.2)
                didLaunch = true
            }
            if Date() >= deadline { throw IPCError.malformed("app_unavailable") }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        defer { connection.close() }
        var frame = try IPCFrame.encode(message)
        if let preprocess { frame = preprocess(frame) }
        try connection.write(frame)

        let reader = Task.detached(priority: .userInitiated) { () -> IPCResponse? in
            guard let header = try? connection.read(4),
                  let length = IPCFrame.decodeLength(header), length > 0,
                  length <= IPCProtocol.maxResponseBytes else { return nil }
            guard let body = try? connection.read(Int(length)) else { return nil }
            return try? IPCFrame.decode(IPCResponse.self, from: body)
        }
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            reader.cancel()
        }
        defer { timeoutTask.cancel() }
        guard let response = await reader.value, response.id == message.id else {
            throw IPCError.malformed("no response")
        }
        return response
    }
}

/// A connected socket file wrapped so it can cross concurrency boundaries
/// (used from exactly one request task at a time).
final class Connection: @unchecked Sendable {
    private let fd: Int32
    private var closed = false

    init?(socketURL: URL) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = socketURL.path
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            path.utf8CString.withUnsafeBytes { source in
                destination.copyBytes(from: source.prefix(destination.count))
            }
        }
        var result: Int32 = -1
        withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                result = Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            return nil
        }
        self.fd = fd
    }

    func write(_ data: Data) throws {
        let sent = data.withUnsafeBytes { raw -> Int in
            send(fd, raw.baseAddress, raw.count, 0)
        }
        if sent < 0 { throw SocketError.last() }
    }

    func read(_ count: Int) throws -> Data {
        var buffer = Data(capacity: count)
        var chunk = [UInt8](repeating: 0, count: count)
        while buffer.count < count {
            let n = recv(fd, &chunk, count - buffer.count, 0)
            if n <= 0 { throw SocketError.last() }
            buffer.append(contentsOf: chunk[0..<n])
        }
        return buffer
    }

    func close() {
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }
}
#endif
