import Foundation
import Darwin

enum TerminalPumpResult {
    case vmStopped
    case detached
    case ioClosed
    case sessionEnded
}

final class TerminalBridge {
    private var masterFD: Int32 = -1
    private var slaveFD: Int32 = -1
    private var savedTermios: termios?
    private var rawModeEnabled = false
    private var sawLogoutMarker = false
    private var outputTail = Data()
    private var sawAnyOutput = false

    deinit {
        restoreTerminalIfNeeded()
        closeIfNeeded(&masterFD)
        closeIfNeeded(&slaveFD)
    }

    func makeSerialAttachment() throws -> (FileHandle, FileHandle) {
        var outMaster: Int32 = -1
        var outSlave: Int32 = -1
        if openpty(&outMaster, &outSlave, nil, nil, nil) != 0 {
            throw MSLRuntimeError("failed to allocate PTY: \(String(cString: strerror(errno)))")
        }
        masterFD = outMaster
        slaveFD = outSlave

        // Forward the host terminal size to the PTY before the guest starts.
        _ = syncWindowSize()

        let readHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
        let writeHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
        return (readHandle, writeHandle)
    }

    func runIOPump(
        shouldContinue: () -> Bool,
        detachByte: UInt8 = 0x1d,
        onFirstOutput: (() -> Void)? = nil
    ) -> TerminalPumpResult {
        enterRawModeIfTTY()
        defer { restoreTerminalIfNeeded() }

        let stdinFD = FileHandle.standardInput.fileDescriptor
        let stdoutFD = FileHandle.standardOutput.fileDescriptor
        var stdinOpen = true
        var pollIdleTicks = 0
        var wakeupPokes = 0
        var didReportFirstOutput = false

        // Kick serial getty immediately to reduce blank time before first prompt.
        _ = write(masterFD, "\r", 1)
        wakeupPokes = 1

        while shouldContinue() {
            var fds: [pollfd] = []
            if stdinOpen {
                fds.append(pollfd(fd: stdinFD, events: Int16(POLLIN), revents: 0))
            }
            fds.append(pollfd(fd: masterFD, events: Int16(POLLIN), revents: 0))

            let ready = poll(&fds, nfds_t(fds.count), 200)
            if ready < 0 {
                if errno == EINTR {
                    _ = syncWindowSize()
                    continue
                }
                break
            }
            if ready == 0 {
                pollIdleTicks += 1
                // If serial stays quiet, repeatedly send CR to wake login prompt quickly.
                if !sawAnyOutput, wakeupPokes < 8, pollIdleTicks >= 2 {
                    _ = write(masterFD, "\r", 1)
                    wakeupPokes += 1
                    pollIdleTicks = 0
                }
                continue
            }
            pollIdleTicks = 0

            var index = 0
            if stdinOpen {
                let stdinEvents = fds[index].revents
                if (stdinEvents & Int16(POLLIN)) != 0 {
                    let stdinResult = pumpStdin(fd: stdinFD, to: masterFD, detachByte: detachByte)
                    if stdinResult == .detached {
                        return .detached
                    }
                    if stdinResult == .closed {
                        stdinOpen = false
                    }
                }
                index += 1
            }
            let masterEvents = fds[index].revents
            if (masterEvents & Int16(POLLIN)) != 0 {
                let masterResult = pumpFromMaster(srcFD: masterFD, dstFD: stdoutFD)
                if masterResult == .sessionEnded {
                    return .sessionEnded
                }
                if masterResult == .closed {
                    break
                }
                if !didReportFirstOutput, sawAnyOutput {
                    didReportFirstOutput = true
                    onFirstOutput?()
                }
            }
        }
        if shouldContinue() {
            return .ioClosed
        }
        return .vmStopped
    }

    func syncWindowSize() -> Bool {
        var size = winsize()
        if ioctl(FileHandle.standardInput.fileDescriptor, TIOCGWINSZ, &size) != 0 {
            return false
        }
        return ioctl(masterFD, TIOCSWINSZ, &size) == 0
    }

    private func enterRawModeIfTTY() {
        let fd = FileHandle.standardInput.fileDescriptor
        guard isatty(fd) == 1 else {
            return
        }
        var term = termios()
        guard tcgetattr(fd, &term) == 0 else {
            return
        }
        savedTermios = term

        var raw = term
        cfmakeraw(&raw)
        if tcsetattr(fd, TCSAFLUSH, &raw) == 0 {
            rawModeEnabled = true
        }
    }

    private func restoreTerminalIfNeeded() {
        guard rawModeEnabled, var term = savedTermios else {
            return
        }
        _ = tcsetattr(FileHandle.standardInput.fileDescriptor, TCSAFLUSH, &term)
        rawModeEnabled = false
    }

    private enum MasterPumpResult {
        case ok
        case closed
        case sessionEnded
    }

    private func pumpFromMaster(srcFD: Int32, dstFD: Int32) -> MasterPumpResult {
        var buffer = [UInt8](repeating: 0, count: 8192)
        let bytesRead = read(srcFD, &buffer, buffer.count)
        if bytesRead == 0 {
            return .closed
        }
        if bytesRead < 0 {
            return (errno == EAGAIN || errno == EINTR) ? .ok : .closed
        }

        let count = Int(bytesRead)
        if !writeAll(dstFD: dstFD, bytes: buffer, count: count) {
            return .closed
        }
        sawAnyOutput = true
        recordOutputTail(bytes: buffer, count: count)
        if detectSessionEnded() {
            return .sessionEnded
        }
        return .ok
    }

    private enum StdinPumpResult {
        case ok
        case closed
        case detached
    }

    private func pumpStdin(fd: Int32, to dstFD: Int32, detachByte: UInt8) -> StdinPumpResult {
        var buffer = [UInt8](repeating: 0, count: 8192)
        let bytesRead = read(fd, &buffer, buffer.count)
        if bytesRead == 0 {
            return .closed
        }
        if bytesRead < 0 {
            if errno == EINTR || errno == EAGAIN {
                return .ok
            }
            return .closed
        }

        let count = Int(bytesRead)
        if let detachIndex = buffer[..<count].firstIndex(of: detachByte) {
            if detachIndex > 0 {
                _ = writeAll(dstFD: dstFD, bytes: buffer, count: detachIndex)
            }
            return .detached
        }

        _ = writeAll(dstFD: dstFD, bytes: buffer, count: count)
        return .ok
    }

    private func writeAll(dstFD: Int32, bytes: [UInt8], count: Int) -> Bool {
        var written = 0
        while written < count {
            let chunk = bytes.withUnsafeBytes { rawPtr -> Int in
                let base = rawPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let ptr = base.advanced(by: written)
                return write(dstFD, ptr, count - written)
            }
            if chunk < 0 {
                if errno == EINTR {
                    continue
                }
                return false
            }
            written += chunk
        }
        return true
    }

    private func recordOutputTail(bytes: [UInt8], count: Int) {
        outputTail.append(bytes, count: count)
        let maxTail = 8192
        if outputTail.count > maxTail {
            outputTail = outputTail.suffix(maxTail)
        }
    }

    private func detectSessionEnded() -> Bool {
        guard let text = String(data: outputTail, encoding: .utf8) else {
            return false
        }
        if !sawLogoutMarker, text.contains("logout") {
            sawLogoutMarker = true
        }
        guard sawLogoutMarker else {
            return false
        }
        if text.contains("msl login:") || text.contains("(automatic login)") {
            return true
        }
        return false
    }

    private func closeIfNeeded(_ fd: inout Int32) {
        if fd >= 0 {
            _ = close(fd)
            fd = -1
        }
    }
}
