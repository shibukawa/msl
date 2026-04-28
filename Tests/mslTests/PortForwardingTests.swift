import XCTest
import Foundation
import Darwin
@testable import mslCore

final class PortForwardingTests: XCTestCase {
    func testLoopbackMappingAcceptsIPv6Connections() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("msl-port-forwarding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let guestPort = try startIPv4EchoServer()
        let hostPort = try findDualStackLoopbackPort()
        let logger = MSLLogger(logFile: tempRoot.appendingPathComponent("msl.log", isDirectory: false))
        let manager = PortForwardingManager(
            logger: logger,
            guestIPResolver: GuestIPResolver(explicitIP: "127.0.0.1"),
            exposeVMNetEndpoints: false
        )
        defer { manager.stopAll() }

        let response = manager.add(PortMapping(hostPort: hostPort, guestPort: guestPort))
        XCTAssertTrue(response.ok, response.error ?? "port mapping failed")

        let reply = try connectIPv6Loopback(port: hostPort, payload: "ping")
        XCTAssertEqual(reply, "pong")
    }

    func testMappingUsesUpdatedGuestIPWithoutRestartingListener() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("msl-port-forwarding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let guestPort = try startIPv4EchoServer()
        let hostPort = try findDualStackLoopbackPort()
        let logger = MSLLogger(logFile: tempRoot.appendingPathComponent("msl.log", isDirectory: false))
        let manager = PortForwardingManager(
            logger: logger,
            guestIPResolver: GuestIPResolver(explicitIP: "192.0.2.1"),
            exposeVMNetEndpoints: false
        )
        defer { manager.stopAll() }

        let response = manager.add(PortMapping(hostPort: hostPort, guestPort: guestPort))
        XCTAssertTrue(response.ok, response.error ?? "port mapping failed")

        manager.updateGuestIP("127.0.0.1")

        let reply = try connectIPv6Loopback(port: hostPort, payload: "ping")
        XCTAssertEqual(reply, "pong")
    }

    private func startIPv4EchoServer() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)

        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bindResult, 0)
        XCTAssertEqual(listen(fd, 1), 0)

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        XCTAssertEqual(nameResult, 0)
        let port = Int(UInt16(bigEndian: bound.sin_port))

        Thread.detachNewThread {
            defer { _ = close(fd) }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            defer { _ = close(client) }

            var buffer = [UInt8](repeating: 0, count: 16)
            _ = read(client, &buffer, buffer.count)
            _ = "pong".withCString { ptr in
                write(client, ptr, 4)
            }
        }

        return port
    }

    private func findDualStackLoopbackPort() throws -> Int {
        for _ in 0..<32 {
            let fd4 = socket(AF_INET, SOCK_STREAM, 0)
            XCTAssertGreaterThanOrEqual(fd4, 0)
            defer { _ = close(fd4) }

            var yes: Int32 = 1
            _ = setsockopt(fd4, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

            var addr4 = sockaddr_in()
            addr4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr4.sin_family = sa_family_t(AF_INET)
            addr4.sin_port = 0
            inet_pton(AF_INET, "127.0.0.1", &addr4.sin_addr)

            let bind4 = withUnsafePointer(to: &addr4) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd4, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            XCTAssertEqual(bind4, 0)

            var bound4 = sockaddr_in()
            var len4 = socklen_t(MemoryLayout<sockaddr_in>.size)
            let name4 = withUnsafeMutablePointer(to: &bound4) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(fd4, $0, &len4)
                }
            }
            XCTAssertEqual(name4, 0)
            let port = Int(UInt16(bigEndian: bound4.sin_port))

            let fd6 = socket(AF_INET6, SOCK_STREAM, 0)
            XCTAssertGreaterThanOrEqual(fd6, 0)
            defer { _ = close(fd6) }
            _ = setsockopt(fd6, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            _ = setsockopt(fd6, IPPROTO_IPV6, IPV6_V6ONLY, &yes, socklen_t(MemoryLayout<Int32>.size))

            var addr6 = sockaddr_in6()
            addr6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr6.sin6_family = sa_family_t(AF_INET6)
            addr6.sin6_port = in_port_t(UInt16(port).bigEndian)
            inet_pton(AF_INET6, "::1", &addr6.sin6_addr)

            let bind6 = withUnsafePointer(to: &addr6) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd6, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
            if bind6 == 0 {
                return port
            }
        }
        throw XCTSkip("failed to reserve dual-stack loopback port")
    }

    private func connectIPv6Loopback(port: Int, payload: String) throws -> String {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { _ = close(fd) }

        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = in_port_t(UInt16(port).bigEndian)
        inet_pton(AF_INET6, "::1", &addr.sin6_addr)

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        XCTAssertEqual(connectResult, 0)

        _ = payload.withCString { ptr in
            write(fd, ptr, strlen(ptr))
        }

        var buffer = [UInt8](repeating: 0, count: 16)
        let count = read(fd, &buffer, buffer.count)
        XCTAssertGreaterThan(count, 0)
        return String(decoding: buffer.prefix(Int(count)), as: UTF8.self)
    }
}
