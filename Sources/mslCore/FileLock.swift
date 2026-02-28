import Foundation
import Darwin

public final class FileLock {
    private let fd: Int32

    public init(path: String) throws {
        fd = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        if fd < 0 {
            let code = errno
            let message = String(cString: strerror(code))
            throw MSLRuntimeError("failed to open lock file: \(path) (\(code): \(message))")
        }
    }

    deinit {
        close(fd)
    }

    public func withExclusiveLock<T>(timeoutSec: Int = 5, _ body: () throws -> T) throws -> T {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSec))
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                break
            }
            if Date() >= deadline {
                throw MSLRuntimeError("runtime busy: failed to acquire lock within \(timeoutSec)s")
            }
            usleep(100_000)
        }

        defer {
            flock(fd, LOCK_UN)
        }
        return try body()
    }
}
