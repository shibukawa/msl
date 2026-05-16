import Foundation
import Darwin

final class SessionStreamBridgeState {
    private let lock = NSLock()
    private var stdinOpen = true
    private var outputClosed = false
    private var exitCode: Int32?
    private var exitReason: String?
    private var failureReason: String?

    func closeStdin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard stdinOpen else { return false }
        stdinOpen = false
        return true
    }

    func observeExit(code: Int32, reason: String?) {
        lock.lock()
        exitCode = code
        exitReason = reason
        lock.unlock()
    }

    func observeOutputClosed() {
        lock.lock()
        outputClosed = true
        lock.unlock()
    }

    func abort(_ reason: String) {
        lock.lock()
        if failureReason == nil {
            failureReason = reason
        }
        lock.unlock()
    }

    var snapshot: (stdinOpen: Bool, outputClosed: Bool, exitCode: Int32?, exitReason: String?, failureReason: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (stdinOpen, outputClosed, exitCode, exitReason, failureReason)
    }
}

struct ProcBridgeResult {
    var exitCode: Int32
    var exitReason: String?
}

struct ProcOutputEvent {
    enum Kind {
        case stdout
        case stderr
    }

    var kind: Kind
    var data: Data
}

struct PtyBridgeResult {
    var exitCode: Int32
    var exitReason: String?
}

enum SessionStreamBridge {
    static func runProc(
        daemonClient: DaemonClient,
        procID: String,
        sessionID: String,
        inputFD: Int32?,
        attachInput: Bool,
        initialInput: Data = Data(),
        onInputChunk: ((Data) -> Void)? = nil,
        onInputClosed: ((String, Int32?) -> Void)? = nil,
        onOutput: @escaping (ProcOutputEvent) -> Bool,
        onExitObserved: ((Int32, String?) -> Void)? = nil
    ) throws -> ProcBridgeResult {
        let state = SessionStreamBridgeState()
        let stream = try daemonClient.procSubscribe(procId: procID)

        if attachInput, let inputFD {
            let thread = Thread {
                pumpProcInput(
                    daemonClient: daemonClient,
                    procID: procID,
                    sessionID: sessionID,
                    inputFD: inputFD,
                    initialInput: initialInput,
                    state: state,
                    onInputChunk: onInputChunk,
                    onInputClosed: onInputClosed
                )
            }
            thread.name = "msl.session.proc.stdin"
            thread.start()
        } else if !initialInput.isEmpty {
            _ = try daemonClient.sendIndependentOneShot(RuntimeControlRequest(
                op: "proc_write",
                timeoutMs: 30_000,
                procId: procID,
                rawData: initialInput,
                sessionId: sessionID
            ))
        }

        while true {
            let event = try stream.nextEvent()
            guard let event else {
                break
            }
            switch event.kind {
            case .stdout:
                if !event.data.isEmpty && !onOutput(ProcOutputEvent(kind: .stdout, data: event.data)) {
                    state.abort("socket_write_failed")
                }
            case .stderr:
                if !event.data.isEmpty && !onOutput(ProcOutputEvent(kind: .stderr, data: event.data)) {
                    state.abort("socket_write_failed")
                }
            case .exited:
                let code = event.exitCode ?? 0
                state.observeExit(code: code, reason: event.text)
                onExitObserved?(code, event.text)
            case .streamsClosed:
                state.observeOutputClosed()
            }

            let snapshot = state.snapshot
            if let failure = snapshot.failureReason {
                throw MSLRuntimeError(failure)
            }
            if snapshot.outputClosed, let exitCode = snapshot.exitCode {
                return ProcBridgeResult(exitCode: exitCode, exitReason: snapshot.exitReason)
            }
        }

        let snapshot = state.snapshot
        if let failure = snapshot.failureReason {
            throw MSLRuntimeError(failure)
        }
        if snapshot.outputClosed, let exitCode = snapshot.exitCode {
            return ProcBridgeResult(exitCode: exitCode, exitReason: snapshot.exitReason)
        }
        guard let exitCode = snapshot.exitCode else {
            throw MSLRuntimeError("subscribe_eof_before_exit")
        }
        return ProcBridgeResult(exitCode: exitCode, exitReason: snapshot.exitReason)
    }

    static func runProc(
        initClient: InitChannelClient,
        procID: String,
        inputFD: Int32?,
        attachInput: Bool,
        initialInput: Data = Data(),
        onInputChunk: ((Data) -> Void)? = nil,
        onInputClosed: ((String, Int32?) -> Void)? = nil,
        onOutput: @escaping (ProcOutputEvent) -> Bool,
        onExitObserved: ((Int32, String?) -> Void)? = nil
    ) throws -> ProcBridgeResult {
        let state = SessionStreamBridgeState()

        if attachInput, let inputFD {
            let thread = Thread {
                pumpInitProcInput(
                    initClient: initClient,
                    procID: procID,
                    inputFD: inputFD,
                    initialInput: initialInput,
                    state: state,
                    onInputChunk: onInputChunk,
                    onInputClosed: onInputClosed
                )
            }
            thread.name = "msl.init.proc.stdin"
            thread.start()
        } else if !initialInput.isEmpty {
            _ = try initClient.procWrite(procId: procID, data: initialInput, timeoutMs: 30_000)
        }

        var exitObserved = false
        while true {
            let response = try initClient.procRead(procId: procID, timeoutMs: 500)
            guard response.ok else {
                throw MSLRuntimeError(response.error?.message ?? "proc_read failed")
            }

            var emittedChunk = false
            for chunk in response.chunks ?? [] {
                switch chunk.stream {
                case "stdout":
                    if let data = chunk.rawData, !data.isEmpty,
                       !onOutput(ProcOutputEvent(kind: .stdout, data: data)) {
                        state.abort("socket_write_failed")
                    }
                    if chunk.rawData?.isEmpty == false {
                        emittedChunk = true
                    }
                case "stderr":
                    if let data = chunk.rawData, !data.isEmpty,
                       !onOutput(ProcOutputEvent(kind: .stderr, data: data)) {
                        state.abort("socket_write_failed")
                    }
                    if chunk.rawData?.isEmpty == false {
                        emittedChunk = true
                    }
                default:
                    break
                }
            }

            if let exitCode = response.exitCode {
                let exitReason = response.meta?["exitReason"]
                state.observeExit(code: exitCode, reason: exitReason)
                if !exitObserved {
                    onExitObserved?(exitCode, exitReason)
                    exitObserved = true
                }
                state.observeOutputClosed()
            }

            let snapshot = state.snapshot
            if let failure = snapshot.failureReason {
                throw MSLRuntimeError(failure)
            }
            if snapshot.outputClosed, let exitCode = snapshot.exitCode {
                return ProcBridgeResult(exitCode: exitCode, exitReason: snapshot.exitReason)
            }
            if !emittedChunk {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }

        let snapshot = state.snapshot
        if let failure = snapshot.failureReason {
            throw MSLRuntimeError(failure)
        }
        if snapshot.outputClosed, let exitCode = snapshot.exitCode {
            return ProcBridgeResult(exitCode: exitCode, exitReason: snapshot.exitReason)
        }
        guard let exitCode = snapshot.exitCode else {
            throw MSLRuntimeError("proc_read_eof_before_exit")
        }
        return ProcBridgeResult(exitCode: exitCode, exitReason: snapshot.exitReason)
    }

    static func runPty(
        daemonClient: DaemonClient,
        ptyID: String,
        sessionID: String,
        inputFD: Int32?,
        initialInput: Data = Data(),
        detachByte: UInt8? = nil,
        onInputChunk: ((Data) -> Void)? = nil,
        onInputClosed: ((String, Int32?) -> Void)? = nil,
        onOutput: @escaping (Data) -> Bool,
        onExitObserved: ((Int32, String?) -> Void)? = nil,
        resizeProvider: (() -> (rows: Int?, cols: Int?))? = nil,
        onResize: ((Int, Int) -> Void)? = nil
    ) throws -> PtyBridgeResult {
        let state = SessionStreamBridgeState()
        let stream = try daemonClient.ptySubscribe(ptyId: ptyID)

        if let inputFD {
            let thread = Thread {
                pumpPtyInput(
                    daemonClient: daemonClient,
                    ptyID: ptyID,
                    sessionID: sessionID,
                    inputFD: inputFD,
                    initialInput: initialInput,
                    detachByte: detachByte,
                    state: state,
                    onInputChunk: onInputChunk,
                    onInputClosed: onInputClosed
                )
            }
            thread.name = "msl.session.pty.stdin"
            thread.start()
        } else if !initialInput.isEmpty {
            _ = try daemonClient.sendIndependentOneShot(RuntimeControlRequest(
                op: "pty_write",
                timeoutMs: 2_000,
                ptyId: ptyID,
                rawData: initialInput,
                sessionId: sessionID
            ))
        }

        if let resizeProvider {
            let resizeThread = Thread {
                pumpPtyResize(
                    daemonClient: daemonClient,
                    ptyID: ptyID,
                    sessionID: sessionID,
                    state: state,
                    resizeProvider: resizeProvider,
                    onResize: onResize
                )
            }
            resizeThread.name = "msl.session.pty.resize"
            resizeThread.start()
        }

        while true {
            let event = try stream.nextEvent()
            guard let event else {
                break
            }
            switch event.kind {
            case .output:
                if !event.data.isEmpty && !onOutput(event.data) {
                    state.abort("pty_output_write_failed")
                }
            case .exited:
                let code = event.exitCode ?? 0
                state.observeExit(code: code, reason: event.text)
                onExitObserved?(code, event.text)
            case .streamsClosed:
                state.observeOutputClosed()
            }

            let snapshot = state.snapshot
            if let failure = snapshot.failureReason {
                throw MSLRuntimeError(failure)
            }
            if snapshot.outputClosed, let exitCode = snapshot.exitCode {
                return PtyBridgeResult(exitCode: exitCode, exitReason: snapshot.exitReason)
            }
        }

        let snapshot = state.snapshot
        if let failure = snapshot.failureReason {
            throw MSLRuntimeError(failure)
        }
        if snapshot.outputClosed, let exitCode = snapshot.exitCode {
            return PtyBridgeResult(exitCode: exitCode, exitReason: snapshot.exitReason)
        }
        guard let exitCode = snapshot.exitCode else {
            throw MSLRuntimeError("pty stream ended before exit")
        }
        return PtyBridgeResult(exitCode: exitCode, exitReason: snapshot.exitReason)
    }

    static func runPty(
        initClient: InitChannelClient,
        ptyID: String,
        inputFD: Int32?,
        initialInput: Data = Data(),
        detachByte: UInt8? = nil,
        onInputChunk: ((Data) -> Void)? = nil,
        onInputClosed: ((String, Int32?) -> Void)? = nil,
        onOutput: @escaping (Data) -> Bool,
        onExitObserved: ((Int32, String?) -> Void)? = nil,
        resizeProvider: (() -> (rows: Int?, cols: Int?))? = nil,
        onResize: ((Int, Int) -> Void)? = nil
    ) throws -> PtyBridgeResult {
        let state = SessionStreamBridgeState()
        let stream = try initClient.ptySubscribe(ptyId: ptyID)

        if let inputFD {
            let thread = Thread {
                pumpInitPtyInput(
                    initClient: initClient,
                    ptyID: ptyID,
                    inputFD: inputFD,
                    initialInput: initialInput,
                    detachByte: detachByte,
                    state: state,
                    onInputChunk: onInputChunk,
                    onInputClosed: onInputClosed
                )
            }
            thread.name = "msl.init.pty.stdin"
            thread.start()
        } else if !initialInput.isEmpty {
            _ = try initClient.ptyWrite(ptyId: ptyID, data: initialInput, timeoutMs: 2_000)
        }

        if let resizeProvider {
            let resizeThread = Thread {
                pumpInitPtyResize(
                    initClient: initClient,
                    ptyID: ptyID,
                    state: state,
                    resizeProvider: resizeProvider,
                    onResize: onResize
                )
            }
            resizeThread.name = "msl.init.pty.resize"
            resizeThread.start()
        }

        while true {
            let event = try stream.nextEvent()
            guard let event else {
                break
            }
            switch event.kind {
            case .output:
                if !event.data.isEmpty && !onOutput(event.data) {
                    state.abort("pty_output_write_failed")
                }
            case .exited:
                let code = event.exitCode ?? 0
                state.observeExit(code: code, reason: event.text)
                onExitObserved?(code, event.text)
            case .streamsClosed:
                state.observeOutputClosed()
            }

            let snapshot = state.snapshot
            if let failure = snapshot.failureReason {
                throw MSLRuntimeError(failure)
            }
            if snapshot.outputClosed, let exitCode = snapshot.exitCode {
                return PtyBridgeResult(exitCode: exitCode, exitReason: snapshot.exitReason)
            }
        }

        let snapshot = state.snapshot
        if let failure = snapshot.failureReason {
            throw MSLRuntimeError(failure)
        }
        if snapshot.outputClosed, let exitCode = snapshot.exitCode {
            return PtyBridgeResult(exitCode: exitCode, exitReason: snapshot.exitReason)
        }
        guard let exitCode = snapshot.exitCode else {
            throw MSLRuntimeError("pty stream ended before exit")
        }
        return PtyBridgeResult(exitCode: exitCode, exitReason: snapshot.exitReason)
    }

    private static func pumpProcInput(
        daemonClient: DaemonClient,
        procID: String,
        sessionID: String,
        inputFD: Int32,
        initialInput: Data,
        state: SessionStreamBridgeState,
        onInputChunk: ((Data) -> Void)?,
        onInputClosed: ((String, Int32?) -> Void)?
    ) {
        let maxBatchBytes = 1024 * 1024
        let coalescePollMs = 5
        var buffer = [UInt8](repeating: 0, count: maxBatchBytes)
        let writerClient = try? daemonClient.makeIndependentPersistentClient()
        defer { writerClient?.disconnect() }

        if !initialInput.isEmpty {
            onInputChunk?(initialInput)
            _ = try? (writerClient?.sendPersistent(RuntimeControlRequest(
                op: "proc_write",
                timeoutMs: 30_000,
                procId: procID,
                rawData: initialInput,
                sessionId: sessionID
            )) ?? daemonClient.sendIndependentOneShot(RuntimeControlRequest(
                op: "proc_write",
                timeoutMs: 30_000,
                procId: procID,
                rawData: initialInput,
                sessionId: sessionID
            )))
        }

        while state.snapshot.failureReason == nil {
            let n = read(inputFD, &buffer, buffer.count)
            if n == 0 {
                guard state.closeStdin() else { return }
                onInputClosed?("stdin_eof", nil)
                _ = try? daemonClient.send(RuntimeControlRequest(op: "proc_stdin_close", procId: procID, sessionId: sessionID))
                return
            }
            if n < 0 {
                if errno == EINTR { continue }
                guard state.closeStdin() else { return }
                onInputClosed?("stdin_read_error", errno)
                _ = try? daemonClient.send(RuntimeControlRequest(op: "proc_stdin_close", procId: procID, sessionId: sessionID))
                return
            }

            var chunk = Data(buffer[0..<Int(n)])
            while chunk.count < maxBatchBytes {
                var pfd = pollfd(fd: inputFD, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, Int32(coalescePollMs))
                if ready <= 0 || (pfd.revents & Int16(POLLIN)) == 0 {
                    break
                }
                let remaining = min(buffer.count, maxBatchBytes - chunk.count)
                let extra = read(inputFD, &buffer, remaining)
                if extra <= 0 {
                    break
                }
                chunk.append(buffer, count: extra)
            }

            onInputChunk?(chunk)
            do {
                let request = RuntimeControlRequest(
                    op: "proc_write",
                    timeoutMs: 30_000,
                    procId: procID,
                    rawData: chunk,
                    sessionId: sessionID
                )
                if let writerClient {
                    _ = try writerClient.sendPersistent(request)
                } else {
                    _ = try daemonClient.sendIndependentOneShot(request)
                }
            } catch {
                state.abort("proc_write_failed")
                return
            }
        }
    }

    private static func pumpInitProcInput(
        initClient: InitChannelClient,
        procID: String,
        inputFD: Int32,
        initialInput: Data,
        state: SessionStreamBridgeState,
        onInputChunk: ((Data) -> Void)?,
        onInputClosed: ((String, Int32?) -> Void)?
    ) {
        let maxBatchBytes = 1024 * 1024
        let coalescePollMs = 5
        var buffer = [UInt8](repeating: 0, count: maxBatchBytes)

        if !initialInput.isEmpty {
            onInputChunk?(initialInput)
            _ = try? initClient.procWrite(procId: procID, data: initialInput, timeoutMs: 30_000)
        }

        while state.snapshot.failureReason == nil {
            let n = read(inputFD, &buffer, buffer.count)
            if n == 0 {
                guard state.closeStdin() else { return }
                onInputClosed?("stdin_eof", nil)
                _ = try? initClient.procStdinClose(procId: procID)
                return
            }
            if n < 0 {
                if errno == EINTR { continue }
                guard state.closeStdin() else { return }
                onInputClosed?("stdin_read_error", errno)
                _ = try? initClient.procStdinClose(procId: procID)
                return
            }

            var chunk = Data(buffer[0..<Int(n)])
            while chunk.count < maxBatchBytes {
                var pfd = pollfd(fd: inputFD, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, Int32(coalescePollMs))
                if ready <= 0 || (pfd.revents & Int16(POLLIN)) == 0 {
                    break
                }
                let remaining = min(buffer.count, maxBatchBytes - chunk.count)
                let extra = read(inputFD, &buffer, remaining)
                if extra <= 0 {
                    break
                }
                chunk.append(buffer, count: extra)
            }

            onInputChunk?(chunk)
            do {
                _ = try initClient.procWrite(procId: procID, data: chunk, timeoutMs: 30_000)
            } catch {
                state.abort("proc_write_failed")
                return
            }
        }
    }

    private static func pumpPtyInput(
        daemonClient: DaemonClient,
        ptyID: String,
        sessionID: String,
        inputFD: Int32,
        initialInput: Data,
        detachByte: UInt8?,
        state: SessionStreamBridgeState,
        onInputChunk: ((Data) -> Void)?,
        onInputClosed: ((String, Int32?) -> Void)?
    ) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        if !initialInput.isEmpty {
            onInputChunk?(initialInput)
            _ = try? daemonClient.sendIndependentOneShot(RuntimeControlRequest(
                op: "pty_write",
                timeoutMs: 2_000,
                ptyId: ptyID,
                rawData: initialInput,
                sessionId: sessionID
            ))
        }
        while state.snapshot.failureReason == nil {
            let n = read(inputFD, &buffer, buffer.count)
            if n == 0 {
                guard state.closeStdin() else { return }
                onInputClosed?("stdin_eof", nil)
                return
            }
            if n < 0 {
                if errno == EINTR { continue }
                guard state.closeStdin() else { return }
                onInputClosed?("stdin_read_error", errno)
                return
            }
            let count = Int(n)
            if let detachByte, let idx = buffer[..<count].firstIndex(of: detachByte) {
                if idx > 0 {
                    let data = Data(buffer[..<idx])
                    onInputChunk?(data)
                    _ = try? daemonClient.sendIndependentOneShot(RuntimeControlRequest(
                        op: "pty_write",
                        timeoutMs: 2_000,
                        ptyId: ptyID,
                        rawData: data,
                        sessionId: sessionID
                    ))
                }
                _ = state.closeStdin()
                _ = try? daemonClient.send(RuntimeControlRequest(op: "pty_close", ptyId: ptyID, sessionId: sessionID))
                onInputClosed?("detach_key", nil)
                return
            }
            let chunk = Data(buffer[..<count])
            onInputChunk?(chunk)
            do {
                _ = try daemonClient.sendIndependentOneShot(RuntimeControlRequest(
                    op: "pty_write",
                    timeoutMs: 2_000,
                    ptyId: ptyID,
                    rawData: chunk,
                    sessionId: sessionID
                ))
            } catch {
                state.abort("pty_write_failed")
                return
            }
        }
    }

    private static func pumpInitPtyInput(
        initClient: InitChannelClient,
        ptyID: String,
        inputFD: Int32,
        initialInput: Data,
        detachByte: UInt8?,
        state: SessionStreamBridgeState,
        onInputChunk: ((Data) -> Void)?,
        onInputClosed: ((String, Int32?) -> Void)?
    ) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        if !initialInput.isEmpty {
            onInputChunk?(initialInput)
            _ = try? initClient.ptyWrite(ptyId: ptyID, data: initialInput, timeoutMs: 2_000)
        }
        while state.snapshot.failureReason == nil {
            let n = read(inputFD, &buffer, buffer.count)
            if n == 0 {
                guard state.closeStdin() else { return }
                onInputClosed?("stdin_eof", nil)
                return
            }
            if n < 0 {
                if errno == EINTR { continue }
                guard state.closeStdin() else { return }
                onInputClosed?("stdin_read_error", errno)
                return
            }

            let chunk = Data(buffer[0..<Int(n)])
            if let detachByte, let index = chunk.firstIndex(of: detachByte) {
                let prefix = chunk.prefix(upTo: index)
                if !prefix.isEmpty {
                    let data = Data(prefix)
                    onInputChunk?(data)
                    _ = try? initClient.ptyWrite(ptyId: ptyID, data: data, timeoutMs: 2_000)
                }
                state.abort("detached")
                return
            }

            onInputChunk?(chunk)
            do {
                _ = try initClient.ptyWrite(ptyId: ptyID, data: chunk, timeoutMs: 2_000)
            } catch {
                state.abort("pty_write_failed")
                return
            }
        }
    }

    private static func pumpInitPtyResize(
        initClient: InitChannelClient,
        ptyID: String,
        state: SessionStreamBridgeState,
        resizeProvider: @escaping () -> (rows: Int?, cols: Int?),
        onResize: ((Int, Int) -> Void)?
    ) {
        var previous: (rows: Int, cols: Int)?
        while state.snapshot.failureReason == nil {
            let size = resizeProvider()
            if let rows = size.rows, let cols = size.cols,
               previous?.rows != rows || previous?.cols != cols {
                previous = (rows, cols)
                _ = try? initClient.ptyResize(ptyId: ptyID, rows: rows, cols: cols, timeoutMs: 2_000)
                onResize?(rows, cols)
            }
            usleep(100_000)
        }
    }

    private static func pumpPtyResize(
        daemonClient: DaemonClient,
        ptyID: String,
        sessionID: String,
        state: SessionStreamBridgeState,
        resizeProvider: () -> (rows: Int?, cols: Int?),
        onResize: ((Int, Int) -> Void)?
    ) {
        var lastRows: Int?
        var lastCols: Int?
        while state.snapshot.exitCode == nil && state.snapshot.failureReason == nil {
            let size = resizeProvider()
            if let rows = size.rows, let cols = size.cols,
               rows != lastRows || cols != lastCols {
                _ = try? daemonClient.sendIndependentOneShot(RuntimeControlRequest(
                    op: "pty_resize",
                    ptyId: ptyID,
                    rows: rows,
                    cols: cols,
                    sessionId: sessionID
                ))
                onResize?(rows, cols)
                lastRows = rows
                lastCols = cols
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}
