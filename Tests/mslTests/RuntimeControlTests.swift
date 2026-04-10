import XCTest
@testable import mslCore

final class RuntimeControlTests: XCTestCase {

    // MARK: - U4: Request encode/decode round-trip

    func testPortAddRequestRoundTrip() throws {
        let req = RuntimeControlRequest(op: "port_add", hostPort: 8080, guestPort: 80)
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(RuntimeControlRequest.self, from: data)
        XCTAssertEqual(decoded.op, "port_add")
        XCTAssertEqual(decoded.hostPort, 8080)
        XCTAssertEqual(decoded.guestPort, 80)
        XCTAssertNil(decoded.argv)
        XCTAssertNil(decoded.timeoutMs)
    }

    func testResponseRoundTrip() throws {
        let resp = RuntimeControlResponse(ok: true, error: nil, items: nil)
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(RuntimeControlResponse.self, from: data)
        XCTAssertTrue(decoded.ok)
        XCTAssertNil(decoded.error)
    }

    func testResponseWithItems() throws {
        let item = RuntimePortStatusItem(
            instance: "ubuntu",
            hostPort: 8080, guestPort: 80,
            bindAddress: "127.0.0.1",
            source: "auto",
            active: true,
            ownerInstance: "alpine",
            guestAddress: "192.168.64.8",
            localhostEndpoint: "127.0.0.1:8080",
            hostnameEndpoint: "ubuntu.msl.localhost:8080",
            directEndpoint: "192.168.64.8:80",
            error: nil
        )
        let resp = RuntimeControlResponse(ok: true, error: nil, items: [item])
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(RuntimeControlResponse.self, from: data)
        XCTAssertEqual(decoded.items?.count, 1)
        XCTAssertEqual(decoded.items?.first?.instance, "ubuntu")
        XCTAssertEqual(decoded.items?.first?.hostPort, 8080)
        XCTAssertEqual(decoded.items?.first?.guestPort, 80)
        XCTAssertEqual(decoded.items?.first?.ownerInstance, "alpine")
        XCTAssertEqual(decoded.items?.first?.active, true)
        XCTAssertEqual(decoded.items?.first?.source, "auto")
        XCTAssertEqual(decoded.items?.first?.guestAddress, "192.168.64.8")
        XCTAssertEqual(decoded.items?.first?.directEndpoint, "192.168.64.8:80")
    }

    // MARK: - U11: New ops request/response format

    func testExecRequestRoundTrip() throws {
        let req = RuntimeControlRequest(
            op: "exec",
            instance: "ubuntu",
            argv: ["echo", "hello"],
            timeoutMs: 30000,
            cwd: "/Users/alice/work"
        )
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(RuntimeControlRequest.self, from: data)
        XCTAssertEqual(decoded.op, "exec")
        XCTAssertEqual(decoded.instance, "ubuntu")
        XCTAssertEqual(decoded.argv, ["echo", "hello"])
        XCTAssertEqual(decoded.cwd, "/Users/alice/work")
        XCTAssertEqual(decoded.timeoutMs, 30000)
        XCTAssertNil(decoded.hostPort)
    }

    func testExecResponseRoundTrip() throws {
        let resp = RuntimeControlResponse(
            ok: true, stdout: "hello\n", stderr: "", exitCode: 0
        )
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(RuntimeControlResponse.self, from: data)
        XCTAssertTrue(decoded.ok)
        XCTAssertEqual(decoded.stdout, "hello\n")
        XCTAssertEqual(decoded.stderr, "")
        XCTAssertEqual(decoded.exitCode, 0)
    }

    func testExecResponseWithNonZeroExitCode() throws {
        let resp = RuntimeControlResponse(
            ok: true, stdout: "", stderr: "error\n", exitCode: 1
        )
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(RuntimeControlResponse.self, from: data)
        XCTAssertEqual(decoded.exitCode, 1)
        XCTAssertEqual(decoded.stderr, "error\n")
    }

    func testPtyOpenRequestRoundTrip() throws {
        let req = RuntimeControlRequest(
            op: "pty_open",
            argv: ["/bin/bash", "-il"],
            rows: 24,
            cols: 80,
            cwd: "/Users/alice/work"
        )
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(RuntimeControlRequest.self, from: data)
        XCTAssertEqual(decoded.op, "pty_open")
        XCTAssertEqual(decoded.argv, ["/bin/bash", "-il"])
        XCTAssertEqual(decoded.cwd, "/Users/alice/work")
        XCTAssertEqual(decoded.rows, 24)
        XCTAssertEqual(decoded.cols, 80)
    }

    func testWorkspacePrepareRequestRoundTrip() throws {
        let req = RuntimeControlRequest(
            op: "workspace_prepare",
            cwd: "/Users/alice/work",
            hostShareRoot: "/Users/alice"
        )
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(RuntimeControlRequest.self, from: data)
        XCTAssertEqual(decoded.op, "workspace_prepare")
        XCTAssertEqual(decoded.cwd, "/Users/alice/work")
        XCTAssertEqual(decoded.hostShareRoot, "/Users/alice")
    }

    func testDNSReconcileRequestRoundTrip() throws {
        let req = RuntimeControlRequest(op: "dns_reconcile", dnsSource: "manual")
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(RuntimeControlRequest.self, from: data)
        XCTAssertEqual(decoded.op, "dns_reconcile")
        XCTAssertEqual(decoded.dnsSource, "manual")
    }

    func testPtyOpenResponseRoundTrip() throws {
        let resp = RuntimeControlResponse(ok: true, ptyId: "pty-123-1")
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(RuntimeControlResponse.self, from: data)
        XCTAssertTrue(decoded.ok)
        XCTAssertEqual(decoded.ptyId, "pty-123-1")
    }

    func testPtyReadResponseWithData() throws {
        let resp = RuntimeControlResponse(
            ok: true, dataBase64: "aGVsbG8K"  // "hello\n" in base64
        )
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(RuntimeControlResponse.self, from: data)
        XCTAssertTrue(decoded.ok)
        XCTAssertEqual(decoded.dataBase64, "aGVsbG8K")
        // Verify base64 decodes correctly
        let rawData = Data(base64Encoded: decoded.dataBase64!)
        XCTAssertEqual(String(data: rawData!, encoding: .utf8), "hello\n")
    }

    func testPtyWriteRequestRoundTrip() throws {
        let req = RuntimeControlRequest(
            op: "pty_write",
            ptyId: "pty-123-1",
            dataBase64: "bHMgLWxhCg=="  // "ls -la\n"
        )
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(RuntimeControlRequest.self, from: data)
        XCTAssertEqual(decoded.op, "pty_write")
        XCTAssertEqual(decoded.ptyId, "pty-123-1")
        XCTAssertEqual(decoded.dataBase64, "bHMgLWxhCg==")
    }

    func testProcWriteRequestRoundTrip() throws {
        let req = RuntimeControlRequest(
            op: "proc_write",
            procId: "proc-123-1",
            dataBase64: "dW5hbWUgLW0K"
        )
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(RuntimeControlRequest.self, from: data)
        XCTAssertEqual(decoded.op, "proc_write")
        XCTAssertEqual(decoded.procId, "proc-123-1")
        XCTAssertEqual(decoded.dataBase64, "dW5hbWUgLW0K")
    }

    func testProcReadResponseWithStreams() throws {
        let resp = RuntimeControlResponse(
            ok: true,
            exitCode: 0,
            procId: "proc-123-1",
            stdoutBase64: "eDg2XzY0Cg==",
            stderrBase64: "",
            chunks: [
                RuntimeControlStreamChunk(stream: "stdout", dataBase64: "Zm9v"),
                RuntimeControlStreamChunk(stream: "stderr", dataBase64: "YmFy")
            ]
        )
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(RuntimeControlResponse.self, from: data)
        XCTAssertEqual(decoded.procId, "proc-123-1")
        XCTAssertEqual(decoded.stdoutBase64, "eDg2XzY0Cg==")
        XCTAssertEqual(decoded.stderrBase64, "")
        XCTAssertEqual(decoded.exitCode, 0)
        XCTAssertEqual(decoded.chunks?.count, 2)
        XCTAssertEqual(decoded.chunks?.first?.stream, "stdout")
        XCTAssertEqual(decoded.chunks?.first?.dataBase64, "Zm9v")
        XCTAssertEqual(decoded.chunks?.last?.stream, "stderr")
        XCTAssertEqual(decoded.chunks?.last?.dataBase64, "YmFy")
    }

    func testPtyResizeRequestRoundTrip() throws {
        let req = RuntimeControlRequest(
            op: "pty_resize",
            ptyId: "pty-1",
            rows: 50, cols: 120
        )
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(RuntimeControlRequest.self, from: data)
        XCTAssertEqual(decoded.op, "pty_resize")
        XCTAssertEqual(decoded.ptyId, "pty-1")
        XCTAssertEqual(decoded.rows, 50)
        XCTAssertEqual(decoded.cols, 120)
    }

    func testSessionRegisterRequestRoundTrip() throws {
        let req = RuntimeControlRequest(op: "session_register")
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(RuntimeControlRequest.self, from: data)
        XCTAssertEqual(decoded.op, "session_register")
    }

    func testSessionRegisterResponseRoundTrip() throws {
        let resp = RuntimeControlResponse(ok: true, sessionId: "abc-123")
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(RuntimeControlResponse.self, from: data)
        XCTAssertTrue(decoded.ok)
        XCTAssertEqual(decoded.sessionId, "abc-123")
    }

    func testSessionUnregisterRequestRoundTrip() throws {
        let req = RuntimeControlRequest(op: "session_unregister", sessionId: "abc-123")
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(RuntimeControlRequest.self, from: data)
        XCTAssertEqual(decoded.op, "session_unregister")
        XCTAssertEqual(decoded.sessionId, "abc-123")
    }

    func testStopRequestRoundTrip() throws {
        let req = RuntimeControlRequest(op: "instance_stop", all: true, callerCwd: "/Users/alice/work")
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(RuntimeControlRequest.self, from: data)
        XCTAssertEqual(decoded.op, "instance_stop")
        XCTAssertEqual(decoded.all, true)
        XCTAssertEqual(decoded.callerCwd, "/Users/alice/work")
    }

    func testInstanceListResponseRoundTrip() throws {
        let item = RuntimeInstanceStatusItem(
            instance: "ubuntu",
            vmState: "Running",
            activeSessionCount: 2,
            idleTimerArmed: false,
            idleDeadlineEpochMs: nil,
            runtimeHostPid: 123,
            lastError: nil,
            lastTransitionEpochMs: 100
        )
        let resp = RuntimeControlResponse(ok: true, instances: [item])
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(RuntimeControlResponse.self, from: data)
        XCTAssertEqual(decoded.instances?.count, 1)
        XCTAssertEqual(decoded.instances?.first?.instance, "ubuntu")
        XCTAssertEqual(decoded.instances?.first?.vmState, "Running")
    }

    func testProvisionStatusRequestRoundTrip() throws {
        let req = RuntimeControlRequest(op: "provision_status")
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(RuntimeControlRequest.self, from: data)
        XCTAssertEqual(decoded.op, "provision_status")
    }

    // MARK: - U12: converge_status response parsing (provision_status → meta)

    func testProvisionStatusResponseWithMeta() throws {
        let resp = RuntimeControlResponse(
            ok: true,
            meta: ["convergence": "done"]
        )
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(RuntimeControlResponse.self, from: data)
        XCTAssertTrue(decoded.ok)
        XCTAssertEqual(decoded.meta?["convergence"], "done")
    }

    func testProvisionStatusRunning() throws {
        let resp = RuntimeControlResponse(
            ok: true,
            meta: ["convergence": "running"]
        )
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(RuntimeControlResponse.self, from: data)
        XCTAssertEqual(decoded.meta?["convergence"], "running")
    }

    func testProvisionStatusError() throws {
        let resp = RuntimeControlResponse(
            ok: true,
            meta: ["convergence": "error"]
        )
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(RuntimeControlResponse.self, from: data)
        XCTAssertEqual(decoded.meta?["convergence"], "error")
    }

    func testProvisionStatusNotStarted() throws {
        let resp = RuntimeControlResponse(
            ok: true,
            meta: ["convergence": "not_started"]
        )
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(RuntimeControlResponse.self, from: data)
        XCTAssertEqual(decoded.meta?["convergence"], "not_started")
    }

    // MARK: - Error response

    func testErrorResponse() throws {
        let resp = RuntimeControlResponse(ok: false, error: "daemon connection lost")
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(RuntimeControlResponse.self, from: data)
        XCTAssertFalse(decoded.ok)
        XCTAssertEqual(decoded.error, "daemon connection lost")
    }

    // MARK: - JSON-over-newline wire format

    func testRequestJsonNewlineFormat() throws {
        let req = RuntimeControlRequest(op: "exec", argv: ["echo", "hello"])
        var data = try JSONEncoder().encode(req)
        data.append(UInt8(ascii: "\n"))
        let str = String(data: data, encoding: .utf8)!
        XCTAssertTrue(str.hasSuffix("\n"))
        // Should be a single line
        let lines = str.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 1)
        // Should be parseable without the newline
        let decoded = try JSONDecoder().decode(
            RuntimeControlRequest.self,
            from: lines[0].data(using: .utf8)!
        )
        XCTAssertEqual(decoded.op, "exec")
    }

    // MARK: - Optional fields default to nil

    func testMinimalRequestFields() throws {
        let json = #"{"op":"stop"}"#
        let decoded = try JSONDecoder().decode(
            RuntimeControlRequest.self, from: json.data(using: .utf8)!
        )
        XCTAssertEqual(decoded.op, "stop")
        XCTAssertNil(decoded.hostPort)
        XCTAssertNil(decoded.instance)
        XCTAssertNil(decoded.all)
        XCTAssertNil(decoded.callerCwd)
        XCTAssertNil(decoded.guestPort)
        XCTAssertNil(decoded.argv)
        XCTAssertNil(decoded.timeoutMs)
        XCTAssertNil(decoded.ptyId)
        XCTAssertNil(decoded.dataBase64)
        XCTAssertNil(decoded.rows)
        XCTAssertNil(decoded.cols)
        XCTAssertNil(decoded.sessionId)
    }

    func testMinimalResponseFields() throws {
        let json = #"{"ok":true}"#
        let decoded = try JSONDecoder().decode(
            RuntimeControlResponse.self, from: json.data(using: .utf8)!
        )
        XCTAssertTrue(decoded.ok)
        XCTAssertNil(decoded.error)
        XCTAssertNil(decoded.items)
        XCTAssertNil(decoded.stdout)
        XCTAssertNil(decoded.stderr)
        XCTAssertNil(decoded.exitCode)
        XCTAssertNil(decoded.ptyId)
        XCTAssertNil(decoded.dataBase64)
        XCTAssertNil(decoded.sessionId)
        XCTAssertNil(decoded.meta)
    }

    func testLargeProcWriteRoundTripOverRuntimeControlSocket() throws {
        let socketPath = NSTemporaryDirectory() + UUID().uuidString + ".sock"
        let server = RuntimeControlServer(socketPath: socketPath) { request in
            let payload = request.rawData ?? Data(base64Encoded: request.dataBase64 ?? "")
            return RuntimeControlResponse(
                ok: true,
                meta: ["bytes": String(payload?.count ?? -1)]
            )
        }
        try server.start()
        defer { server.stop() }

        let client = RuntimeControlClient(socketPath: socketPath)
        let payload = Data(repeating: 0x5a, count: 96 * 1024)
        let response = try client.send(RuntimeControlRequest(
            op: "proc_write",
            procId: "proc-large-1",
            rawData: payload
        ))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.meta?["bytes"], String(payload.count))
    }

    func testOneMegProcWriteRoundTripOverRuntimeControlSocket() throws {
        let socketPath = NSTemporaryDirectory() + UUID().uuidString + ".sock"
        let server = RuntimeControlServer(socketPath: socketPath) { request in
            let payload = request.rawData ?? Data(base64Encoded: request.dataBase64 ?? "")
            return RuntimeControlResponse(
                ok: true,
                meta: ["bytes": String(payload?.count ?? -1)]
            )
        }
        try server.start()
        defer { server.stop() }

        let client = RuntimeControlClient(socketPath: socketPath)
        let payload = Data(repeating: 0x41, count: 1024 * 1024)
        let response = try client.send(RuntimeControlRequest(
            op: "proc_write",
            procId: "proc-large-2",
            rawData: payload
        ))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.meta?["bytes"], String(payload.count))
    }

    func testDirectProcReadPreservesOrderedChunksOverRuntimeControlSocket() throws {
        let socketPath = NSTemporaryDirectory() + UUID().uuidString + ".sock"
        let server = RuntimeControlServer(socketPath: socketPath) { request in
            XCTAssertEqual(request.op, "proc_read")
            XCTAssertEqual(request.procId, "proc-ordered-1")

            var c1 = RuntimeControlStreamChunk(stream: "stdout", dataBase64: Data("out-1".utf8).base64EncodedString())
            c1.rawData = Data("out-1".utf8)
            var c2 = RuntimeControlStreamChunk(stream: "stderr", dataBase64: Data("err-1".utf8).base64EncodedString())
            c2.rawData = Data("err-1".utf8)
            var c3 = RuntimeControlStreamChunk(stream: "stdout", dataBase64: Data("out-2".utf8).base64EncodedString())
            c3.rawData = Data("out-2".utf8)

            return RuntimeControlResponse(
                ok: true,
                exitCode: 0,
                procId: "proc-ordered-1",
                chunks: [c1, c2, c3],
                meta: ["exitCode": "0", "exitReason": "exited"]
            )
        }
        try server.start()
        defer { server.stop() }

        let client = RuntimeControlClient(socketPath: socketPath)
        let response = try client.send(RuntimeControlRequest(
            op: "proc_read",
            timeoutMs: 200,
            procId: "proc-ordered-1"
        ))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.procId, "proc-ordered-1")
        XCTAssertEqual(response.exitCode, 0)
        XCTAssertEqual(response.meta?["exitReason"], "exited")
        XCTAssertEqual(response.chunks?.map { $0.stream }, ["stdout", "stderr", "stdout"])
        XCTAssertEqual(response.chunks?.compactMap { $0.rawData }.map { String(data: $0, encoding: .utf8)! }, ["out-1", "err-1", "out-2"])
        XCTAssertEqual(String(data: response.rawStdout ?? Data(), encoding: .utf8), "out-1out-2")
        XCTAssertEqual(String(data: response.rawStderr ?? Data(), encoding: .utf8), "err-1")
    }

    func testPtyReadRoundTripOverRuntimeControlSocket() throws {
        let socketPath = NSTemporaryDirectory() + UUID().uuidString + ".sock"
        let server = RuntimeControlServer(socketPath: socketPath) { request in
            XCTAssertEqual(request.op, "pty_read")
            XCTAssertEqual(request.ptyId, "pty-test-1")
            return RuntimeControlResponse(
                ok: true,
                exitCode: nil,
                ptyId: "pty-test-1",
                rawData: Data("hello\r\n".utf8)
            )
        }
        try server.start()
        defer { server.stop() }

        let client = RuntimeControlClient(socketPath: socketPath)
        let response = try client.send(RuntimeControlRequest(
            op: "pty_read",
            ptyId: "pty-test-1"
        ))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.ptyId, "pty-test-1")
        XCTAssertEqual(response.rawData, Data("hello\r\n".utf8))
        XCTAssertEqual(response.dataBase64, Data("hello\r\n".utf8).base64EncodedString())
    }

    func testAsyncProcWriteDoesNotDesyncPersistentConnection() throws {
        let socketPath = NSTemporaryDirectory() + UUID().uuidString + ".sock"
        final class CounterBox {
            private let lock = NSLock()
            private var value = 0
            func add(_ amount: Int) {
                lock.lock()
                value += amount
                lock.unlock()
            }
            func get() -> Int {
                lock.lock()
                let current = value
                lock.unlock()
                return current
            }
        }
        let total = CounterBox()
        let server = RuntimeControlServer(socketPath: socketPath) { request in
            if request.op == "proc_write" {
                let payload = request.rawData ?? Data(base64Encoded: request.dataBase64 ?? "")
                total.add(payload?.count ?? 0)
                return RuntimeControlResponse(ok: true)
            }
            return RuntimeControlResponse(ok: true, sessionId: "session-1")
        }
        try server.start()
        defer { server.stop() }

        let client = RuntimeControlClient(socketPath: socketPath)
        try client.connect()
        defer { client.disconnect() }

        let payload = Data(repeating: 0x7f, count: 128 * 1024)
        try client.sendPersistentNoReply(RuntimeControlRequest(
            op: "proc_write",
            procId: "proc-async-1",
            rawData: payload
        ))
        let syncResponse = try client.sendPersistent(RuntimeControlRequest(op: "session_register"))

        XCTAssertTrue(syncResponse.ok)
        XCTAssertEqual(syncResponse.sessionId, "session-1")
        XCTAssertEqual(total.get(), payload.count)
    }

    func testProcSubscribeStreamRoundTripOverRuntimeControlSocket() throws {
        let socketPath = NSTemporaryDirectory() + UUID().uuidString + ".sock"
        let server = RuntimeControlServer(
            socketPath: socketPath,
            handler: { _ in
                XCTFail("unexpected request-response handler invocation")
                return RuntimeControlResponse(ok: false)
            },
            streamHandler: { request, fd in
                XCTAssertEqual(request.op, "proc_subscribe")
                XCTAssertEqual(request.procId, "proc-sub-1")
                do {
                    let stdoutHeader = RuntimeControlEventHeader(
                        kind: RuntimeControlProcEventKind.stdout.rawValue,
                        ptyId: nil,
                        procId: "proc-sub-1",
                        exitCode: nil,
                        text: nil
                    )
                    try runtimeControlWriteAll(fd: fd, data: runtimeControlEncodeFrame(
                        opcode: .procEvent,
                        header: try JSONEncoder().encode(stdoutHeader),
                        payload: Data("hello".utf8)
                    ))
                    let exitHeader = RuntimeControlEventHeader(
                        kind: RuntimeControlProcEventKind.exited.rawValue,
                        ptyId: nil,
                        procId: "proc-sub-1",
                        exitCode: 7,
                        text: "exited"
                    )
                    try runtimeControlWriteAll(fd: fd, data: runtimeControlEncodeFrame(
                        opcode: .procEvent,
                        header: try JSONEncoder().encode(exitHeader),
                        payload: Data()
                    ))
                    let closedHeader = RuntimeControlEventHeader(
                        kind: RuntimeControlProcEventKind.streamsClosed.rawValue,
                        ptyId: nil,
                        procId: "proc-sub-1",
                        exitCode: nil,
                        text: nil
                    )
                    try runtimeControlWriteAll(fd: fd, data: runtimeControlEncodeFrame(
                        opcode: .procEvent,
                        header: try JSONEncoder().encode(closedHeader),
                        payload: Data()
                    ))
                    return true
                } catch {
                    XCTFail("stream handler error: \(error)")
                    return false
                }
            }
        )
        try server.start()
        defer { server.stop() }

        let client = RuntimeControlClient(socketPath: socketPath)
        let stream = try client.procSubscribe(procId: "proc-sub-1")

        let event1 = try stream.nextEvent()
        XCTAssertEqual(event1?.procId, "proc-sub-1")
        XCTAssertEqual(event1?.kind, .stdout)
        XCTAssertEqual(String(data: event1?.data ?? Data(), encoding: .utf8), "hello")

        let event2 = try stream.nextEvent()
        XCTAssertEqual(event2?.kind, .exited)
        XCTAssertEqual(event2?.exitCode, 7)
        XCTAssertEqual(event2?.text, "exited")

        let event3 = try stream.nextEvent()
        XCTAssertEqual(event3?.kind, .streamsClosed)
    }

    func testPtySubscribeStreamRoundTripOverRuntimeControlSocket() throws {
        let socketPath = NSTemporaryDirectory() + UUID().uuidString + ".sock"
        let server = RuntimeControlServer(
            socketPath: socketPath,
            handler: { _ in
                XCTFail("unexpected request-response handler invocation")
                return RuntimeControlResponse(ok: false)
            },
            streamHandler: { request, fd in
                XCTAssertEqual(request.op, "pty_subscribe")
                XCTAssertEqual(request.ptyId, "pty-sub-1")
                do {
                    let outputHeader = RuntimeControlEventHeader(
                        kind: RuntimeControlPtyEventKind.output.rawValue,
                        ptyId: "pty-sub-1",
                        procId: nil,
                        exitCode: nil,
                        text: nil
                    )
                    try runtimeControlWriteAll(fd: fd, data: runtimeControlEncodeFrame(
                        opcode: .ptyEvent,
                        header: try JSONEncoder().encode(outputHeader),
                        payload: Data("tty-out".utf8)
                    ))
                    let exitHeader = RuntimeControlEventHeader(
                        kind: RuntimeControlPtyEventKind.exited.rawValue,
                        ptyId: "pty-sub-1",
                        procId: nil,
                        exitCode: 0,
                        text: "exited"
                    )
                    try runtimeControlWriteAll(fd: fd, data: runtimeControlEncodeFrame(
                        opcode: .ptyEvent,
                        header: try JSONEncoder().encode(exitHeader),
                        payload: Data()
                    ))
                    let closedHeader = RuntimeControlEventHeader(
                        kind: RuntimeControlPtyEventKind.streamsClosed.rawValue,
                        ptyId: "pty-sub-1",
                        procId: nil,
                        exitCode: nil,
                        text: nil
                    )
                    try runtimeControlWriteAll(fd: fd, data: runtimeControlEncodeFrame(
                        opcode: .ptyEvent,
                        header: try JSONEncoder().encode(closedHeader),
                        payload: Data()
                    ))
                    return true
                } catch {
                    XCTFail("stream handler error: \(error)")
                    return false
                }
            }
        )
        try server.start()
        defer { server.stop() }

        let client = RuntimeControlClient(socketPath: socketPath)
        let stream = try client.ptySubscribe(ptyId: "pty-sub-1")

        let event1 = try stream.nextEvent()
        XCTAssertEqual(event1?.ptyId, "pty-sub-1")
        XCTAssertEqual(event1?.kind, .output)
        XCTAssertEqual(String(data: event1?.data ?? Data(), encoding: .utf8), "tty-out")

        let event2 = try stream.nextEvent()
        XCTAssertEqual(event2?.kind, .exited)
        XCTAssertEqual(event2?.exitCode, 0)
        XCTAssertEqual(event2?.text, "exited")

        let event3 = try stream.nextEvent()
        XCTAssertEqual(event3?.kind, .streamsClosed)
    }
}
