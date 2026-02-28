import Foundation
import Darwin

struct HostTerminalState {
    private let fd: Int32
    private let original: termios?

    static func capture(fd: Int32 = FileHandle.standardInput.fileDescriptor) -> HostTerminalState {
        guard isatty(fd) == 1 else {
            return HostTerminalState(fd: fd, original: nil)
        }
        var term = termios()
        if tcgetattr(fd, &term) == 0 {
            return HostTerminalState(fd: fd, original: term)
        }
        return HostTerminalState(fd: fd, original: nil)
    }

    func restore() {
        guard var term = original else {
            return
        }
        _ = tcsetattr(fd, TCSAFLUSH, &term)
    }
}
