import XCTest
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
            if let data = try? JSONEncoder().encode(response) {
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
}
