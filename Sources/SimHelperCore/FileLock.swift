import Foundation

/// flock(2) lock. The kernel drops it when the holder dies, so a killed build
/// never leaves a stale claim behind for cleanup to trip over.
public final class FileLock {
    public enum Mode { case shared, exclusive }

    private var fd: Int32

    private init(fd: Int32) { self.fd = fd }

    deinit { release() }

    public func release() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    /// Waits for the lock.
    public static func acquire(_ path: String, _ mode: Mode) throws -> FileLock {
        guard let lock = try open(path, mode, blocking: true) else {
            throw HelperError(.stateCorrupt, "Could not lock \(path).")
        }
        return lock
    }

    /// Returns nil when another process holds a conflicting lock.
    public static func tryAcquire(_ path: String, _ mode: Mode) throws -> FileLock? {
        try open(path, mode, blocking: false)
    }

    private static func open(_ path: String, _ mode: Mode, blocking: Bool) throws -> FileLock? {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        // O_CLOEXEC: a daemon xcodebuild leaves running must not inherit the claim.
        let fd = Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw HelperError(.stateCorrupt, "Could not open \(path): \(String(cString: strerror(errno))).")
        }
        let operation = (mode == .shared ? LOCK_SH : LOCK_EX) | (blocking ? 0 : LOCK_NB)
        while flock(fd, operation) != 0 {
            if errno == EINTR { continue }
            let failure = errno
            close(fd)
            if failure == EWOULDBLOCK { return nil }
            throw HelperError(.stateCorrupt, "Could not lock \(path): \(String(cString: strerror(failure))).")
        }
        return FileLock(fd: fd)
    }
}
