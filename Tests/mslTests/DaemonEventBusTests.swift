import XCTest
import Foundation
import Darwin
@testable import mslCore

final class DaemonEventBusTests: XCTestCase {
    func testSubscriberReceivesPublishedInstanceStateEvent() throws {
        let fixture = try EventBusFixture()
        defer { fixture.cleanup() }

        let clientFD = try connectUnixSocket(path: fixture.socketPath)
        defer { _ = close(clientFD) }
        try writeLine(fd: clientFD, line: #"{"op":"subscribe","topics":["instance_state"]}"#)
        usleep(80_000)

        fixture.bus.publish(
            topic: "instance_state",
            type: "instance_state_changed",
            instance: "ubuntu",
            state: "Running",
            meta: ["reason": "boot_ready"]
        )

        let line = try readLine(fd: clientFD, timeoutMs: 2_000)
        let envelope = try JSONDecoder().decode(DaemonEventEnvelope.self, from: Data(line.utf8))
        XCTAssertEqual(envelope.topic, "instance_state")
        XCTAssertEqual(envelope.type, "instance_state_changed")
        XCTAssertEqual(envelope.instance, "ubuntu")
        XCTAssertEqual(envelope.state, "Running")
        XCTAssertEqual(envelope.meta?["reason"], "boot_ready")
    }

    func testSubscriberTopicFilterSkipsUnsubscribedTopic() throws {
        let fixture = try EventBusFixture()
        defer { fixture.cleanup() }

        let clientFD = try connectUnixSocket(path: fixture.socketPath)
        defer { _ = close(clientFD) }
        try writeLine(fd: clientFD, line: #"{"op":"subscribe","topics":["instance_health"]}"#)
        usleep(80_000)

        fixture.bus.publish(
            topic: "instance_state",
            type: "instance_state_changed",
            instance: "alpine",
            state: "Stopped",
            meta: ["reason": "idle_timeout"]
        )

        XCTAssertNil(try readLineIfAvailable(fd: clientFD, timeoutMs: 250))
    }
}

private struct EventBusFixture {
    let root: URL
    let socketPath: String
    let bus: DaemonEventBus

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-eventbus-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let nonce = UUID().uuidString.prefix(8)
        socketPath = "/tmp/msl-ev-\(getpid())-\(nonce).sock"
        let loggerPath = root.appendingPathComponent("eventbus.log", isDirectory: false)
        let logger = MSLLogger(logFile: loggerPath)
        bus = DaemonEventBus(socketPath: socketPath, logger: logger)
        try bus.start()
    }

    func cleanup() {
        bus.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

private func connectUnixSocket(path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw MSLRuntimeError("socket create failed")
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
        _ = close(fd)
        throw MSLRuntimeError("socket path too long")
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.initializeMemory(as: CChar.self, repeating: 0)
        for (index, value) in bytes.enumerated() {
            raw[index] = value
        }
    }

    let addrLen = socklen_t(MemoryLayout.size(ofValue: addr))
    let result = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, addrLen)
        }
    }
    guard result == 0 else {
        let message = String(cString: strerror(errno))
        _ = close(fd)
        throw MSLRuntimeError("connect failed: \(message)")
    }
    return fd
}

private func writeLine(fd: Int32, line: String) throws {
    var payload = Data(line.utf8)
    payload.append(UInt8(ascii: "\n"))
    let written = payload.withUnsafeBytes { raw in
        write(fd, raw.baseAddress, raw.count)
    }
    guard written == payload.count else {
        throw MSLRuntimeError("write failed")
    }
}

private func readLine(fd: Int32, timeoutMs: Int32) throws -> String {
    if let line = try readLineIfAvailable(fd: fd, timeoutMs: timeoutMs) {
        return line
    }
    throw MSLRuntimeError("timed out waiting for line")
}

private func readLineIfAvailable(fd: Int32, timeoutMs: Int32) throws -> String? {
    var buffer = Data()
    let start = Date()

    while Date().timeIntervalSince(start) * 1000 < Double(timeoutMs) {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pfd, 1, 20)
        if ready < 0 {
            throw MSLRuntimeError("poll failed")
        }
        if ready == 0 {
            continue
        }
        if (pfd.revents & Int16(POLLIN)) == 0 {
            continue
        }

        var chunk = [UInt8](repeating: 0, count: 1024)
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 {
            return nil
        }
        buffer.append(chunk, count: n)
        if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[..<newline]
            return String(data: line, encoding: .utf8)
        }
    }

    return nil
}
