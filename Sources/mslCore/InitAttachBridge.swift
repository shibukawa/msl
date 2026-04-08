import Foundation
import Darwin

final class InitAttachBridge {
    private var savedTermios: termios?
    private var rawModeEnabled = false

    func run(
        client: InitChannelClient,
        logger: MSLLogger?,
        shouldContinue: @escaping () -> Bool,
        onFirstOutput: (() -> Void)? = nil
    ) throws -> Int32 {
        let size = currentWindowSize()
        let open = try client.ptyOpen(argv: ["/bin/sh", "-l"], rows: size.rows, cols: size.cols, timeoutMs: 3_000)
        guard open.ok, let ptyId = open.ptyId else {
            let code = open.error?.code.rawValue ?? InitChannelErrorCode.internalError.rawValue
            let message = open.error?.message ?? "pty_open failed"
            throw MSLRuntimeError("init pty_open failed (\(code)): \(message)")
        }

        logger?.log("init_pty_opened", fields: ["ptyId": ptyId])
        defer {
            if let close = try? client.ptyClose(ptyId: ptyId, timeoutMs: 500) {
                logger?.log("init_pty_closed", fields: [
                    "ptyId": ptyId,
                    "exit": String(close.exitCode ?? 0)
                ])
            } else {
                logger?.log("init_pty_closed", fields: ["ptyId": ptyId])
            }
        }

        enterRawModeIfTTY()
        defer { restoreTerminalIfNeeded() }

        let eventStream = try client.ptySubscribe(ptyId: ptyId)
        let stdinFD = FileHandle.standardInput.fileDescriptor
        let inputThread = Thread { [self] in
            while shouldContinue() {
                let readResult = self.readStdinChunk(fd: stdinFD)
                switch readResult {
                case .detached:
                    _ = try? client.ptyClose(ptyId: ptyId, timeoutMs: 500)
                    return
                case .closed:
                    return
                case .bytes(let data):
                    _ = try? client.ptyWrite(ptyId: ptyId, data: data, timeoutMs: 2_000)
                case .none:
                    Thread.sleep(forTimeInterval: 0.03)
                }
            }
        }
        inputThread.name = "msl.initattach.stdin"
        inputThread.start()

        let resizeThread = Thread { [self] in
            var lastRows = size.rows
            var lastCols = size.cols
            while shouldContinue() {
                let current = self.currentWindowSize()
                if let rows = current.rows, let cols = current.cols,
                   rows != lastRows || cols != lastCols {
                    _ = try? client.ptyResize(ptyId: ptyId, rows: rows, cols: cols, timeoutMs: 300)
                    logger?.log("init_pty_resize_forwarded", fields: [
                        "ptyId": ptyId,
                        "rows": String(rows),
                        "cols": String(cols)
                    ])
                    lastRows = rows
                    lastCols = cols
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        resizeThread.name = "msl.initattach.resize"
        resizeThread.start()

        var sawOutput = false
        while shouldContinue() {
            guard let event = try eventStream.nextEvent() else {
                break
            }
            switch event.kind {
            case .output:
                if !event.data.isEmpty {
                    FileHandle.standardOutput.write(event.data)
                    if !sawOutput {
                        sawOutput = true
                        onFirstOutput?()
                    }
                }
            case .exited:
                return event.exitCode ?? 0
            case .streamsClosed:
                return 0
            }
        }

        return 1
    }

    private enum StdinReadResult {
        case none
        case closed
        case detached
        case bytes(Data)
    }

    private func readStdinChunk(fd: Int32, detachByte: UInt8 = 0x1d) -> StdinReadResult {
        var buffer = [UInt8](repeating: 0, count: 8192)
        let bytesRead = read(fd, &buffer, buffer.count)
        if bytesRead == 0 {
            return .closed
        }
        if bytesRead < 0 {
            if errno == EINTR || errno == EAGAIN {
                return .none
            }
            return .closed
        }

        let count = Int(bytesRead)
        if let detachIndex = buffer[..<count].firstIndex(of: detachByte) {
            if detachIndex > 0 {
                return .bytes(Data(buffer[..<detachIndex]))
            }
            return .detached
        }
        return .bytes(Data(buffer[..<count]))
    }

    private func currentWindowSize() -> (rows: Int?, cols: Int?) {
        var size = winsize()
        if ioctl(FileHandle.standardInput.fileDescriptor, TIOCGWINSZ, &size) != 0 {
            return (nil, nil)
        }
        return (Int(size.ws_row), Int(size.ws_col))
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
}
