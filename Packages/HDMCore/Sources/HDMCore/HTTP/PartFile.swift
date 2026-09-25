import Darwin
import Foundation

public enum PartFileError: Error, Equatable, Sendable {
    case diskFull
    case closed
    case io(Int32)
}

/// Positional writer for a `.hdmpart` file; safe to call from several threads.
public final class PartFile: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var fd: Int32

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fd = Darwin.open(url.path, O_RDWR | O_CREAT, 0o644)
        if fd < 0 { throw PartFileError.io(errno) }
    }

    deinit { close() }

    /// Grows the file to `size` (sparse on APFS); never shrinks it.
    public func resize(atLeast size: Int64) throws {
        try lock.withLock {
            guard fd >= 0 else { throw PartFileError.closed }
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw PartFileError.io(errno) }
            if info.st_size < size, ftruncate(fd, off_t(size)) != 0 {
                throw errno == ENOSPC ? PartFileError.diskFull : PartFileError.io(errno)
            }
        }
    }

    /// Sets the exact file length (drops stale bytes left by an earlier, longer attempt).
    public func truncate(to size: Int64) throws {
        try lock.withLock {
            guard fd >= 0 else { throw PartFileError.closed }
            if ftruncate(fd, off_t(size)) != 0 { throw PartFileError.io(errno) }
        }
    }

    public func write(_ data: Data, at offset: Int64) throws {
        try lock.withLock {
            guard fd >= 0 else { throw PartFileError.closed }
            guard !data.isEmpty else { return }
            try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var written = 0
                while written < raw.count {
                    let n = Darwin.pwrite(fd, raw.baseAddress! + written, raw.count - written, off_t(offset) + off_t(written))
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw errno == ENOSPC ? PartFileError.diskFull : PartFileError.io(errno)
                    }
                    written += n
                }
            }
        }
    }

    public func close() {
        lock.withLock {
            if fd >= 0 { Darwin.close(fd); fd = -1 }
        }
    }
}
