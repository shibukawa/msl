import Foundation
import Darwin

public struct RuntimeControlRequest: Codable {
    public var op: String
    public var instance: String?
    public var all: Bool?
    public var callerCwd: String?
    public var hostPort: Int?
    public var guestPort: Int?
    // exec / pty / session ops
    public var argv: [String]?
    public var timeoutMs: Int?
    public var runAsRoot: Bool?
    public var ptyId: String?
    public var dataBase64: String?
    public var rows: Int?
    public var cols: Int?
    public var sessionId: String?
    public var cwd: String?
    public var hostShareRoot: String?
    public var dnsSource: String?
}

public struct RuntimePortStatusItem: Codable {
    public var instance: String?
    public var hostPort: Int
    public var guestPort: Int
    public var bindAddress: String
    public var active: Bool
    public var ownerInstance: String?
    public var error: String?

    public init(
        instance: String? = nil,
        hostPort: Int,
        guestPort: Int,
        bindAddress: String,
        active: Bool,
        ownerInstance: String? = nil,
        error: String?
    ) {
        self.instance = instance
        self.hostPort = hostPort
        self.guestPort = guestPort
        self.bindAddress = bindAddress
        self.active = active
        self.ownerInstance = ownerInstance
        self.error = error
    }
}

public struct RuntimeInstanceStatusItem: Codable {
    public var instance: String
    public var vmState: String
    public var activeSessionCount: Int
    public var idleTimerArmed: Bool
    public var idleDeadlineEpochMs: Int64?
    public var runtimeHostPid: Int32?
    public var lastError: String?
    public var lastTransitionEpochMs: Int64
}

public struct RuntimeControlResponse: Codable {
    public var ok: Bool
    public var error: String?
    public var items: [RuntimePortStatusItem]?
    public var instances: [RuntimeInstanceStatusItem]?
    // exec / pty / session responses
    public var stdout: String?
    public var stderr: String?
    public var exitCode: Int32?
    public var ptyId: String?
    public var dataBase64: String?
    public var sessionId: String?
    public var meta: [String: String]?
}

final class RuntimeControlServer {
    private let socketPath: String
    private let handler: (RuntimeControlRequest) -> RuntimeControlResponse
    private var listenFD: Int32 = -1
    private var thread: Thread?
    private var running = false

    init(socketPath: String, handler: @escaping (RuntimeControlRequest) -> RuntimeControlResponse) {
        self.socketPath = socketPath
        self.handler = handler
    }

    func start() throws {
        if running { return }
        try removeSocketIfExists()

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        if listenFD < 0 {
            throw MSLRuntimeError("failed to create runtime control socket: \(lastErr())")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        if pathBytes.count >= MemoryLayout.size(ofValue: addr.sun_path) {
            throw MSLRuntimeError("runtime control socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.initializeMemory(as: CChar.self, repeating: 0)
            for (i, b) in pathBytes.enumerated() {
                raw[i] = b
            }
        }

        let addrLen = socklen_t(MemoryLayout.size(ofValue: addr))
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, addrLen)
            }
        }
        if bindResult != 0 {
            throw MSLRuntimeError("failed to bind runtime control socket: \(lastErr())")
        }
        if listen(listenFD, 16) != 0 {
            throw MSLRuntimeError("failed to listen runtime control socket: \(lastErr())")
        }

        running = true
        thread = Thread { [weak self] in
            self?.acceptLoop()
        }
        thread?.name = "msl.runtime.control"
        thread?.start()
    }

    func stop() {
        guard running else { return }
        running = false
        if listenFD >= 0 {
            _ = shutdown(listenFD, SHUT_RDWR)
            _ = close(listenFD)
            listenFD = -1
        }
        try? removeSocketIfExists()
    }

    private func acceptLoop() {
        while running {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                if running { usleep(50_000) }
                continue
            }
            let thread = Thread { [weak self] in
                self?.handlePersistentClient(clientFD)
                _ = close(clientFD)
            }
            thread.name = "msl.control.client"
            thread.start()
        }
    }

    private func handlePersistentClient(_ fd: Int32) {
        var leftover = Data()
        while running {
            guard let request = readOneRequest(fd: fd, leftover: &leftover) else {
                break  // connection closed or error
            }
            let resp = handler(request)
            writeResponse(resp, to: fd)
        }
    }

    private func readOneRequest(fd: Int32, leftover: inout Data) -> RuntimeControlRequest? {
        // Check if leftover already has a complete line
        if let nlIndex = leftover.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = leftover[leftover.startIndex..<nlIndex]
            leftover = Data(leftover[(nlIndex + 1)...])
            return try? JSONDecoder().decode(RuntimeControlRequest.self, from: lineData)
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { return nil }
            leftover.append(buffer, count: n)

            if let nlIndex = leftover.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = leftover[leftover.startIndex..<nlIndex]
                leftover = Data(leftover[(nlIndex + 1)...])
                return try? JSONDecoder().decode(RuntimeControlRequest.self, from: lineData)
            }

            if leftover.count > 64 * 1024 {
                return nil
            }
        }
    }

    private func writeResponse(_ response: RuntimeControlResponse, to fd: Int32) {
        guard let encoded = try? JSONEncoder().encode(response) else {
            return
        }
        var payload = encoded
        payload.append(UInt8(ascii: "\n"))
        _ = payload.withUnsafeBytes { raw in
            write(fd, raw.baseAddress, raw.count)
        }
    }

    private func removeSocketIfExists() throws {
        if FileManager.default.fileExists(atPath: socketPath) {
            try FileManager.default.removeItem(atPath: socketPath)
        }
    }

    private func lastErr() -> String {
        String(cString: strerror(errno))
    }
}

final class RuntimeControlClient {
    private let socketPath: String
    private var persistentFD: Int32 = -1
    private var leftover = Data()

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    deinit {
        disconnect()
    }

    /// Single-shot send: connect, send, receive, disconnect.
    func send(_ request: RuntimeControlRequest) throws -> RuntimeControlResponse {
        let fd = try connectOnce()
        defer { _ = close(fd) }
        return try sendOnFD(request, fd: fd)
    }

    /// Establish a persistent connection for multiple request-response pairs.
    func connect() throws {
        if persistentFD >= 0 { return }
        persistentFD = try connectOnce()
        leftover = Data()
    }

    /// Send a request on the persistent connection.
    func sendPersistent(_ request: RuntimeControlRequest) throws -> RuntimeControlResponse {
        guard persistentFD >= 0 else {
            throw MSLRuntimeError("not connected to daemon control socket")
        }
        return try sendOnFD(request, fd: persistentFD, persistent: true)
    }

    /// Close the persistent connection.
    func disconnect() {
        if persistentFD >= 0 {
            _ = close(persistentFD)
            persistentFD = -1
            leftover = Data()
        }
    }

    private func sendOnFD(_ request: RuntimeControlRequest, fd: Int32, persistent: Bool = false) throws -> RuntimeControlResponse {
        var payload = try JSONEncoder().encode(request)
        payload.append(UInt8(ascii: "\n"))
        _ = payload.withUnsafeBytes { raw in
            write(fd, raw.baseAddress, raw.count)
        }

        if persistent {
            return try readResponsePersistent(fd: fd)
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        var data = Data()
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
            if buffer.prefix(Int(n)).contains(UInt8(ascii: "\n")) {
                break
            }
            if data.count > 64 * 1024 {
                break
            }
        }

        let line = String(data: data, encoding: .utf8)?
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first ?? ""
        guard let lineData = String(line).data(using: .utf8) else {
            throw MSLRuntimeError("invalid runtime control response")
        }
        return try JSONDecoder().decode(RuntimeControlResponse.self, from: lineData)
    }

    private func readResponsePersistent(fd: Int32) throws -> RuntimeControlResponse {
        // Check leftover first
        if let nlIndex = leftover.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = leftover[leftover.startIndex..<nlIndex]
            leftover = Data(leftover[(nlIndex + 1)...])
            return try JSONDecoder().decode(RuntimeControlResponse.self, from: lineData)
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 {
                throw MSLRuntimeError("daemon control socket closed")
            }
            leftover.append(buffer, count: n)

            if let nlIndex = leftover.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = leftover[leftover.startIndex..<nlIndex]
                leftover = Data(leftover[(nlIndex + 1)...])
                return try JSONDecoder().decode(RuntimeControlResponse.self, from: lineData)
            }

            if leftover.count > 64 * 1024 {
                throw MSLRuntimeError("daemon control response too large")
            }
        }
    }

    private func connectOnce() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 {
            throw MSLRuntimeError("failed to create control client socket: \(String(cString: strerror(errno)))")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        if pathBytes.count >= MemoryLayout.size(ofValue: addr.sun_path) {
            _ = close(fd)
            throw MSLRuntimeError("runtime control socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.initializeMemory(as: CChar.self, repeating: 0)
            for (i, b) in pathBytes.enumerated() {
                raw[i] = b
            }
        }

        let addrLen = socklen_t(MemoryLayout.size(ofValue: addr))
        let conn = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, addrLen)
            }
        }
        if conn != 0 {
            _ = close(fd)
            throw MSLRuntimeError("runtime control socket unavailable")
        }
        return fd
    }
}
