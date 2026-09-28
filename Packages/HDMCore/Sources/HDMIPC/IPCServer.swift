import Foundation

#if canImport(Darwin)
import Darwin

/// Listens on the Unix domain socket and hands each framed request to a handler (spec §7.2).
/// One request → one response per connection; `hdm-bridge` and the Safari appex both speak this.
public final class IPCServer: @unchecked Sendable {
    public typealias Handler = @Sendable (IPCMessage) async -> IPCResponse

    private let queue = DispatchQueue(label: "hdm.ipc.server", attributes: .concurrent)
    private let handler: Handler
    private var serverFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let socketURL: URL

    public init(socketURL: URL = IPCProtocol.socketPath(), handler: @escaping Handler) {
        self.socketURL = socketURL
        self.handler = handler
    }

    /// Removes a stale socket from a previous run and starts listening. Permissions are 0600:
    /// only this user's processes (extension bridge, appex) may connect (spec §10).
    public func start() throws {
        try? FileManager.default.removeItem(at: socketURL)
        try FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = socketURL.path
        guard path.utf8.count + 1 <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            throw IPCError.malformed("socket path too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            path.utf8CString.withUnsafeBytes { source in
                destination.copyBytes(from: source.prefix(destination.count))
            }
        }
        var bindResult: Int32 = -1
        withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bindResult = Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EINVAL)
        }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else {
            let code = errno
            Darwin.close(fd)
            try? FileManager.default.removeItem(at: socketURL)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EINVAL)
        }
        serverFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnections() }
        source.resume()
        acceptSource = source
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if serverFD >= 0 {
            Darwin.close(serverFD)
            serverFD = -1
        }
        try? FileManager.default.removeItem(at: socketURL)
    }

    private func acceptConnections() {
        while true {
            var address = sockaddr()
            var length = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(serverFD, &address, &length)
            guard client >= 0 else { return }
            serve(clientFD: client)
        }
    }

    private func serve(clientFD: Int32) {
        final class ClientSocket: @unchecked Sendable {
            let fd: Int32
            init(_ fd: Int32) { self.fd = fd }
            deinit { Darwin.close(fd) }
            func read(_ count: Int) throws -> Data {
                var buffer = Data(capacity: count)
                var chunk = [UInt8](repeating: 0, count: count)
                while buffer.count < count {
                    let n = recv(fd, &chunk, count - buffer.count, 0)
                    if n <= 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNRESET) }
                    buffer.append(contentsOf: chunk[0..<n])
                }
                return buffer
            }
            func write(_ data: Data) throws {
                let sent = data.withUnsafeBytes { raw -> Int in
                    send(fd, raw.baseAddress, raw.count, 0)
                }
                if sent < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNRESET) }
            }
        }

        let client = ClientSocket(clientFD)
        Task.detached { [handler] in
            let reply: IPCResponse
            do {
                let header = try client.read(4)
                guard let length = IPCFrame.decodeLength(header), length > 0,
                      length <= IPCProtocol.maxRequestBytes else { throw IPCError.tooLarge(-1) }
                let body = try client.read(Int(length))
                let message = try IPCFrame.decode(IPCMessage.self, from: body)
                reply = await handler(message)
            } catch let error as IPCError {
                reply = IPCResponse(id: "", ok: false, error: "\(error)")
            } catch {
                reply = IPCResponse(id: "", ok: false, error: "bad_request")
            }
            try? client.write(IPCFrame.encode(reply))
        }
    }
}
#endif
