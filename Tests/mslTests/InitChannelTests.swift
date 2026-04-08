import XCTest
import Darwin
@testable import mslCore

final class InitChannelTests: XCTestCase {
    func testRequestEncodeDecodeRoundTrip() throws {
        let client = InitChannelClient(socketPath: "/tmp/does-not-exist.sock")
        let request = InitChannelRequest(
            op: "exec",
            argv: ["/bin/echo", "hello"],
            envAdditions: ["FOO": "bar"],
            cwd: "/tmp",
            hostShareRoot: "/Users/tester",
            timeoutMs: 500
        )

        let encoded = try client.encode(request)
        let decoded = try JSONDecoder().decode(InitChannelRequest.self, from: encoded)
        XCTAssertEqual(decoded.op, "exec")
        XCTAssertEqual(decoded.argv, ["/bin/echo", "hello"])
        XCTAssertEqual(decoded.envAdditions?["FOO"], "bar")
        XCTAssertEqual(decoded.cwd, "/tmp")
        XCTAssertEqual(decoded.hostShareRoot, "/Users/tester")
        XCTAssertEqual(decoded.timeoutMs, 500)
    }

    func testConvergeUserRequestEncodeDecodeRoundTrip() throws {
        let request = InitChannelRequest(
            op: "converge_user",
            timeoutMs: 20_000,
            convergeUsername: "alice",
            convergeUID: 501,
            convergeGID: 20,
            convergeHome: "/home/alice",
            convergePreferredShell: "/bin/bash",
            convergeFailOnUIDConflict: true,
            policyTemplateId: "ubuntu-useradd-v1",
            policyCommandFamily: "useradd",
            policyAdminGroup: "sudo",
            policySudoEnabled: true,
            policySudoRequireBinary: false,
            policySudoDropInPath: "/etc/sudoers.d/msl-user",
            policySudoPasswordless: true,
            policySuEnabled: true,
            policySuPasswordless: true,
            policyShellFallbacks: ["/bin/bash", "/bin/sh"],
            policyWelcomeEnabled: true,
            policyWelcomeFrequency: "daily",
            policyWelcomeRespectHushlogin: true,
            policyWelcomeInstance: "ubuntu"
        )

        let client = InitChannelClient(socketPath: "/tmp/does-not-exist.sock")
        let encoded = try client.encode(request)
        let decoded = try JSONDecoder().decode(InitChannelRequest.self, from: encoded)

        XCTAssertEqual(decoded.op, "converge_user")
        XCTAssertEqual(decoded.convergeUsername, "alice")
        XCTAssertEqual(decoded.convergeUID, 501)
        XCTAssertEqual(decoded.convergeGID, 20)
        XCTAssertEqual(decoded.convergeHome, "/home/alice")
        XCTAssertEqual(decoded.convergePreferredShell, "/bin/bash")
        XCTAssertEqual(decoded.convergeFailOnUIDConflict, true)
        XCTAssertEqual(decoded.policyTemplateId, "ubuntu-useradd-v1")
        XCTAssertEqual(decoded.policyCommandFamily, "useradd")
        XCTAssertEqual(decoded.policyAdminGroup, "sudo")
        XCTAssertEqual(decoded.policySudoPasswordless, true)
        XCTAssertEqual(decoded.policySuEnabled, true)
        XCTAssertEqual(decoded.policySuPasswordless, true)
        XCTAssertEqual(decoded.policyShellFallbacks ?? [], ["/bin/bash", "/bin/sh"])
        XCTAssertEqual(decoded.policyWelcomeFrequency, "daily")
        XCTAssertEqual(decoded.policyWelcomeInstance, "ubuntu")
    }

    func testDNSReconcileRequestEncodeDecodeRoundTrip() throws {
        let request = InitChannelRequest(
            op: "dns_reconcile",
            timeoutMs: 3_000,
            dnsMode: "host",
            dnsNameservers: ["1.1.1.1", "8.8.8.8"],
            dnsSearchDomains: ["corp.example"],
            dnsResolverBackend: "replace_resolv_conf",
            dnsSource: "manual",
            dnsProxyUpstreams: ["1.1.1.1", "8.8.8.8"],
            dnsProxyListenAddress: "127.0.0.1",
            dnsProxyListenPort: 53
        )

        let client = InitChannelClient(socketPath: "/tmp/does-not-exist.sock")
        let encoded = try client.encode(request)
        let decoded = try JSONDecoder().decode(InitChannelRequest.self, from: encoded)

        XCTAssertEqual(decoded.op, "dns_reconcile")
        XCTAssertEqual(decoded.dnsMode, "host")
        XCTAssertEqual(decoded.dnsNameservers ?? [], ["1.1.1.1", "8.8.8.8"])
        XCTAssertEqual(decoded.dnsSearchDomains ?? [], ["corp.example"])
        XCTAssertEqual(decoded.dnsResolverBackend, "replace_resolv_conf")
        XCTAssertEqual(decoded.dnsSource, "manual")
        XCTAssertEqual(decoded.dnsProxyUpstreams ?? [], ["1.1.1.1", "8.8.8.8"])
        XCTAssertEqual(decoded.dnsProxyListenAddress, "127.0.0.1")
        XCTAssertEqual(decoded.dnsProxyListenPort, 53)
    }

    func testResponseDecodeRoundTrip() throws {
        let response = InitChannelResponse(
            requestId: "req-1",
            op: "ping",
            status: "ok",
            meta: ["version": "1"]
        )
        let encoded = try JSONEncoder().encode(response)

        let client = InitChannelClient(socketPath: "/tmp/does-not-exist.sock")
        let decoded = try client.decode(encoded)
        XCTAssertTrue(decoded.ok)
        XCTAssertEqual(decoded.requestId, "req-1")
        XCTAssertEqual(decoded.op, "ping")
        XCTAssertEqual(decoded.meta?["version"], "1")
    }

    func testPtyResizeResponseDecodesStringMetaFields() throws {
        let response = InitChannelResponse(
            requestId: "req-pty-resize-1",
            op: "pty_resize",
            status: "ok",
            meta: ["rows": "27", "cols": "120"]
        )
        let raw = try JSONEncoder().encode(response)

        let client = InitChannelClient(socketPath: "/tmp/does-not-exist.sock")
        let decoded = try client.decode(raw)
        XCTAssertTrue(decoded.ok)
        XCTAssertEqual(decoded.op, "pty_resize")
        XCTAssertEqual(decoded.meta?["rows"], "27")
        XCTAssertEqual(decoded.meta?["cols"], "120")
    }

    func testJSONRPCFrameRoundTrip() throws {
        let client = InitChannelClient(socketPath: "/tmp/does-not-exist.sock")
        let request = InitChannelRequest(op: "ping")

        let frame = try client.makeJSONRPCRequestFrame(request)
        let decodedFrame = try client.decodeFrame(frame)
        XCTAssertEqual(decodedFrame.opcode, .jsonRPCRequest)
        XCTAssertTrue(decodedFrame.header.isEmpty)

        let decodedRequest = try JSONDecoder().decode(InitChannelRequest.self, from: decodedFrame.payload)
        XCTAssertEqual(decodedRequest.requestId, request.requestId)
        XCTAssertEqual(decodedRequest.op, "ping")
    }

    func testProcRequestEncodeDecodeRoundTrip() throws {
        let client = InitChannelClient(socketPath: "/tmp/does-not-exist.sock")
        let request = InitChannelRequest(
            op: "proc_write",
            timeoutMs: 250,
            procId: "proc-1",
            dataBase64: "dW5hbWUgLW0K"
        )

        let encoded = try client.encode(request)
        let decoded = try JSONDecoder().decode(InitChannelRequest.self, from: encoded)
        XCTAssertEqual(decoded.op, "proc_write")
        XCTAssertEqual(decoded.procId, "proc-1")
        XCTAssertEqual(decoded.dataBase64, "dW5hbWUgLW0K")
        XCTAssertEqual(decoded.timeoutMs, 250)
    }

    func testProcResponseDecodeRoundTrip() throws {
        let response = InitChannelResponse(
            requestId: "req-proc-1",
            op: "proc_read",
            status: "ok",
            exitCode: 0,
            procId: "proc-1",
            stdoutBase64: "eDg2XzY0Cg==",
            stderrBase64: "",
            chunks: [
                InitChannelStreamChunk(stream: "stdout", dataBase64: "Zm9v"),
                InitChannelStreamChunk(stream: "stderr", dataBase64: "YmFy")
            ]
        )
        let encoded = try JSONEncoder().encode(response)

        let client = InitChannelClient(socketPath: "/tmp/does-not-exist.sock")
        let decoded = try client.decode(encoded)
        XCTAssertTrue(decoded.ok)
        XCTAssertEqual(decoded.procId, "proc-1")
        XCTAssertEqual(decoded.stdoutBase64, "eDg2XzY0Cg==")
        XCTAssertEqual(decoded.stderrBase64, "")
        XCTAssertEqual(decoded.exitCode, 0)
        XCTAssertEqual(decoded.chunks?.count, 2)
        XCTAssertEqual(decoded.chunks?.first?.stream, "stdout")
        XCTAssertEqual(decoded.chunks?.first?.dataBase64, "Zm9v")
        XCTAssertEqual(decoded.chunks?.last?.stream, "stderr")
        XCTAssertEqual(decoded.chunks?.last?.dataBase64, "YmFy")
    }

    func testSendFallsBackToFileHandoff() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-init-handoff-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let handoff = root.appendingPathComponent("handoff.json")
        let ack = root.appendingPathComponent("ack.json")
        let client = InitChannelClient(
            socketPath: "/tmp/definitely-missing-msl-init.sock",
            handoffPath: handoff.path,
            ackPath: ack.path,
            retryCount: 1,
            retryDelayMs: 1,
            timeoutMs: 1000
        )

        let request = InitChannelRequest(op: "ping")
        let requestId = request.requestId
        DispatchQueue.global().async {
            while !FileManager.default.fileExists(atPath: handoff.path) {
                usleep(20_000)
            }
            let response = InitChannelResponse(
                requestId: requestId,
                op: "ping",
                status: "ok",
                meta: ["server": "test"]
            )
            if
                let payload = try? JSONEncoder().encode(response),
                let data = try? client.encodeFrame(opcode: .jsonRPCResponse, header: Data(), payload: payload)
            {
                try? data.write(to: ack, options: .atomic)
            }
        }

        let response = try client.send(request)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.requestId, requestId)
        XCTAssertEqual(response.meta?["server"], "test")
    }

    func testUnavailableErrorMentionsSocketPath() {
        let client = InitChannelClient(
            socketPath: "/tmp/msl-init-no-such.sock",
            retryCount: 1,
            retryDelayMs: 1,
            timeoutMs: 10
        )
        let request = InitChannelRequest(op: "ping")
        XCTAssertThrowsError(try client.send(request)) { error in
            guard let runtime = error as? MSLRuntimeError else {
                return XCTFail("unexpected error type: \(error)")
            }
            XCTAssertTrue(runtime.message.contains("/tmp/msl-init-no-such.sock"))
        }
    }

    func testProcWriteReusesPersistentSidebandConnection() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer {
            _ = close(fds[0])
            _ = close(fds[1])
        }

        let serverFD = fds[1]
        let serverReady = expectation(description: "server processed proc_write requests")
        DispatchQueue.global().async {
            let helper = InitChannelClient(socketPath: "/tmp/does-not-exist.sock")
            defer { serverReady.fulfill() }
            do {
                for _ in 0..<2 {
                    let frame = try helper.readFrameForTest(from: serverFD, op: "proc_write")
                    let decoded = try helper.decodeFrame(frame)
                    XCTAssertEqual(decoded.opcode, .procWriteRequest)
                    let requestHeader = try JSONSerialization.jsonObject(with: decoded.header) as? [String: Any]
                    let requestId = requestHeader?["requestId"] as? String ?? ""
                    let procId = requestHeader?["procId"] as? String ?? ""
                    let header = """
                    {"version":1,"requestId":"\(requestId)","op":"proc_write","status":"ok","procId":"\(procId)"}
                    """
                    let response = try helper.encodeFrame(
                        opcode: .procWriteResponse,
                        header: Data(header.utf8),
                        payload: Data()
                    )
                    response.withUnsafeBytes { raw in
                        guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                        var offset = 0
                        while offset < raw.count {
                            let written = write(serverFD, base.advanced(by: offset), raw.count - offset)
                            XCTAssertGreaterThanOrEqual(written, 0)
                            offset += written
                        }
                    }
                }
            } catch {
                XCTFail("server side failed: \(error)")
            }
        }

        var connectorCalls = 0
        let client = InitChannelClient(
            socketPath: "/tmp/does-not-exist.sock",
            sidebandConnector: {
                connectorCalls += 1
                return (fds[0], nil)
            },
            sidebandSupported: true,
            allowSocketFallback: false,
            allowStreamingOnVsock: true
        )

        let response1 = try client.procWrite(procId: "proc-1", data: Data("hello".utf8), timeoutMs: 1000)
        let response2 = try client.procWrite(procId: "proc-1", data: Data("world".utf8), timeoutMs: 1000)

        XCTAssertTrue(response1.ok)
        XCTAssertTrue(response2.ok)
        XCTAssertEqual(connectorCalls, 1)
        wait(for: [serverReady], timeout: 2)
    }
}
