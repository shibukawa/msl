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

        let stdinFD = FileHandle.standardInput.fileDescriptor
        var stdinOpen = true
        var sawOutput = false
        var lastRows = size.rows
        var lastCols = size.cols
        var consecutiveErrors = 0
        let maxConsecutiveErrors = 50

        // Adaptive backoff: reduce vsock load when idle, stay responsive when active.
        // Under heavy guest I/O (e.g. cloud-init), vsock latency spikes and frequent
        // ptyRead requests saturate the transport, causing cascading timeouts.
        var idleCount = 0
        let baseIdleMs: TimeInterval = 0.05  // 50ms immediately after output
        let maxIdleMs: TimeInterval = 0.5    // 500ms cap when deeply idle

        while shouldContinue() {
            let currentSize = currentWindowSize()
            if let rows = currentSize.rows, let cols = currentSize.cols,
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

            // Poll stdin with adaptive timeout: short when active, longer when idle.
            // This also paces the ptyRead rate — we don't send another ptyRead until
            // the stdin poll completes.
            let stdinPollMs: Int32
            if idleCount <= 2 {
                stdinPollMs = 30        // Active: responsive to typing
            } else if idleCount <= 10 {
                stdinPollMs = 100       // Idle: moderate pace
            } else {
                stdinPollMs = 250       // Deeply idle: slow pace, save vsock bandwidth
            }

            if stdinOpen {
                var fds = [pollfd(fd: stdinFD, events: Int16(POLLIN), revents: 0)]
                let ready = poll(&fds, 1, stdinPollMs)
                if ready > 0, (fds[0].revents & Int16(POLLIN)) != 0 {
                    let readResult = readStdinChunk(fd: stdinFD)
                    switch readResult {
                    case .detached:
                        return 0
                    case .closed:
                        stdinOpen = false
                    case .bytes(let data):
                        do {
                            _ = try client.ptyWrite(ptyId: ptyId, data: data, timeoutMs: 2_000)
                            consecutiveErrors = 0
                            idleCount = 0 // User is active
                        } catch {
                            consecutiveErrors += 1
                            logger?.log("init_pty_write_transient_error", fields: [
                                "ptyId": ptyId,
                                "error": String(describing: error),
                                "consecutive": String(consecutiveErrors)
                            ])
                            if consecutiveErrors >= maxConsecutiveErrors {
                                throw error
                            }
                            Thread.sleep(forTimeInterval: 0.5)
                            continue
                        }
                    case .none:
                        break
                    }
                }
            }

            do {
                let read = try client.ptyRead(ptyId: ptyId, timeoutMs: 1_000)
                guard read.ok else {
                    let code = read.error?.code.rawValue ?? InitChannelErrorCode.internalError.rawValue
                    let message = read.error?.message ?? "pty_read failed"
                    throw MSLRuntimeError("init pty_read failed (\(code)): \(message)")
                }
                consecutiveErrors = 0

                let hasOutput: Bool
                if let payload = read.dataBase64, let out = Data(base64Encoded: payload), !out.isEmpty {
                    FileHandle.standardOutput.write(out)
                    hasOutput = true
                    idleCount = 0 // Got output, reset idle
                    if !sawOutput {
                        sawOutput = true
                        onFirstOutput?()
                    }
                } else {
                    hasOutput = false
                    idleCount += 1
                }

                if let exitCode = read.exitCode {
                    return exitCode
                }
                if let exitRaw = read.meta?["exitCode"], let exitCode = Int32(exitRaw) {
                    return exitCode
                }

                // Adaptive sleep: scale backoff with idle count
                if !hasOutput {
                    let sleepSec = min(baseIdleMs + Double(idleCount) * 0.02, maxIdleMs)
                    Thread.sleep(forTimeInterval: sleepSec)
                }
            } catch {
                consecutiveErrors += 1
                let desc = String(describing: error)
                let isTransient = desc.contains("timeout") || desc.contains("poll failed")
                if isTransient && consecutiveErrors < maxConsecutiveErrors {
                    logger?.log("init_pty_read_transient_error", fields: [
                        "ptyId": ptyId,
                        "error": desc,
                        "consecutive": String(consecutiveErrors)
                    ])
                    // Exponential backoff on transient errors: 0.5s, 1s, 2s, ... capped at 5s
                    let backoff = min(0.5 * pow(2.0, Double(consecutiveErrors - 1)), 5.0)
                    Thread.sleep(forTimeInterval: backoff)
                    continue
                }
                throw error
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
