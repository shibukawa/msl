import Foundation
import Darwin

struct HostTerminalState {
    struct Entry {
        let fd: Int32
        let original: termios
    }

    static let newlineRecoverySequence = "\r\u{1b}[20l"

    private let entries: [Entry]

    static func capture() -> HostTerminalState {
        let candidates = [
            FileHandle.standardInput.fileDescriptor,
            FileHandle.standardOutput.fileDescriptor,
            FileHandle.standardError.fileDescriptor
        ]
        var entries: [Entry] = []
        var seenTTYs = Set<String>()

        for fd in candidates {
            guard isatty(fd) == 1 else {
                continue
            }
            var statInfo = stat()
            guard fstat(fd, &statInfo) == 0 else {
                continue
            }
            let ttyKey = "\(statInfo.st_dev):\(statInfo.st_ino)"
            guard !seenTTYs.contains(ttyKey) else {
                continue
            }
            var term = termios()
            guard tcgetattr(fd, &term) == 0 else {
                continue
            }
            seenTTYs.insert(ttyKey)
            entries.append(Entry(fd: fd, original: term))
        }

        return HostTerminalState(entries: entries)
    }

    func restore() {
        for entry in entries {
            var term = entry.original
            _ = tcsetattr(entry.fd, TCSAFLUSH, &term)
        }
        if isatty(FileHandle.standardOutput.fileDescriptor) == 1 {
            let data = Data(Self.newlineRecoverySequence.utf8)
            _ = data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return -1 }
                return write(FileHandle.standardOutput.fileDescriptor, base, raw.count)
            }
        }
    }
}
