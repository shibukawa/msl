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
            hostPort: 8080, guestPort: 80,
            bindAddress: "127.0.0.1", active: true, error: nil
        )
        let resp = RuntimeControlResponse(ok: true, error: nil, items: [item])
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(RuntimeControlResponse.self, from: data)
        XCTAssertEqual(decoded.items?.count, 1)
        XCTAssertEqual(decoded.items?.first?.hostPort, 8080)
        XCTAssertEqual(decoded.items?.first?.guestPort, 80)
        XCTAssertEqual(decoded.items?.first?.active, true)
    }

    // MARK: - U11: New ops request/response format

    func testExecRequestRoundTrip() throws {
        let req = RuntimeControlRequest(
            op: "exec",
            argv: ["echo", "hello"],
            timeoutMs: 30000,
            cwd: "/Users/alice/work"
        )
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(RuntimeControlRequest.self, from: data)
        XCTAssertEqual(decoded.op, "exec")
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
        let req = RuntimeControlRequest(op: "stop")
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(RuntimeControlRequest.self, from: data)
        XCTAssertEqual(decoded.op, "stop")
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
            meta: ["cloud_init": "done"]
        )
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(RuntimeControlResponse.self, from: data)
        XCTAssertTrue(decoded.ok)
        XCTAssertEqual(decoded.meta?["cloud_init"], "done")
    }

    func testProvisionStatusRunning() throws {
        let resp = RuntimeControlResponse(
            ok: true,
            meta: ["cloud_init": "running"]
        )
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(RuntimeControlResponse.self, from: data)
        XCTAssertEqual(decoded.meta?["cloud_init"], "running")
    }

    func testProvisionStatusError() throws {
        let resp = RuntimeControlResponse(
            ok: true,
            meta: ["cloud_init": "error", "cloud_init_detail": "E: apt-get failed"]
        )
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(RuntimeControlResponse.self, from: data)
        XCTAssertEqual(decoded.meta?["cloud_init"], "error")
        XCTAssertEqual(decoded.meta?["cloud_init_detail"], "E: apt-get failed")
    }

    func testProvisionStatusNotStarted() throws {
        let resp = RuntimeControlResponse(
            ok: true,
            meta: ["cloud_init": "not_started"]
        )
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(RuntimeControlResponse.self, from: data)
        XCTAssertEqual(decoded.meta?["cloud_init"], "not_started")
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
}
