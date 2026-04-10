import Foundation
import Darwin

public struct ManagerControlRequest: Codable, Equatable {
    public var op: String
    public var instance: String?
    public var callerCwd: String?
    public var hostShareRoot: String?
    public var pid: Int32?
    public var runtimeRoot: String?
    public var controlSocketPath: String?
    public var eventSocketPath: String?
    public var lifecycleState: RuntimeLifecycleState?
    public var startupStep: Int?
    public var startupStepName: String?
    public var lastErrorMessage: String?

    public init(
        op: String,
        instance: String? = nil,
        callerCwd: String? = nil,
        hostShareRoot: String? = nil,
        pid: Int32? = nil,
        runtimeRoot: String? = nil,
        controlSocketPath: String? = nil,
        eventSocketPath: String? = nil,
        lifecycleState: RuntimeLifecycleState? = nil,
        startupStep: Int? = nil,
        startupStepName: String? = nil,
        lastErrorMessage: String? = nil
    ) {
        self.op = op
        self.instance = instance
        self.callerCwd = callerCwd
        self.hostShareRoot = hostShareRoot
        self.pid = pid
        self.runtimeRoot = runtimeRoot
        self.controlSocketPath = controlSocketPath
        self.eventSocketPath = eventSocketPath
        self.lifecycleState = lifecycleState
        self.startupStep = startupStep
        self.startupStepName = startupStepName
        self.lastErrorMessage = lastErrorMessage
    }
}

public struct ManagerControlResponse: Codable, Equatable {
    public var ok: Bool
    public var error: String?
    public var worker: AppManagerWorkerRecord?
    public var workers: [AppManagerWorkerRecord]?

    public init(
        ok: Bool,
        error: String? = nil,
        worker: AppManagerWorkerRecord? = nil,
        workers: [AppManagerWorkerRecord]? = nil
    ) {
        self.ok = ok
        self.error = error
        self.worker = worker
        self.workers = workers
    }
}

private enum ManagerSocketIO {
    static func setUnixPath(_ path: String, on addr: inout sockaddr_un) throws {
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else {
            throw MSLRuntimeError("manager socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { rawBuffer in
            rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in bytes.enumerated() {
                rawBuffer[index] = byte
            }
        }
    }

    static func send<T: Encodable>(_ payload: T, to fd: Int32) throws {
        let data = try JSONEncoder().encode(payload)
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if written < 0 {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += written
            }
        }
        shutdown(fd, SHUT_WR)
    }

    static func receiveAll(from fd: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 {
                break
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            data.append(buffer, count: count)
        }
        return data
    }

    static func makeSocket(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        try setUnixPath(path, on: &addr)
        unlink(path)
        var bindAddr = addr
        let bindResult = withUnsafePointer(to: &bindAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        if bindResult != 0 {
            let error = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
        if listen(fd, 32) != 0 {
            let error = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
        return fd
    }
}

public final class ManagerControlServer {
    private let socketPath: String
    private let handler: (ManagerControlRequest) -> ManagerControlResponse
    private let acceptQueue = DispatchQueue(label: "msl.manager.control.server.accept")
    private let clientQueue = DispatchQueue(label: "msl.manager.control.server.client", attributes: .concurrent)
    private var serverFD: Int32 = -1
    private var running = false

    public init(socketPath: String, handler: @escaping (ManagerControlRequest) -> ManagerControlResponse) {
        self.socketPath = socketPath
        self.handler = handler
    }

    public func start() throws {
        let parent = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        serverFD = try ManagerSocketIO.makeSocket(path: socketPath)
        running = true
        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    public func stop() {
        running = false
        if serverFD >= 0 {
            close(serverFD)
            serverFD = -1
        }
        if FileManager.default.fileExists(atPath: socketPath) {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
    }

    private func acceptLoop() {
        while running {
            let clientFD = accept(serverFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR || errno == EAGAIN {
                    continue
                }
                break
            }
            clientQueue.async { [handler] in
                defer { close(clientFD) }
                do {
                    let data = try ManagerSocketIO.receiveAll(from: clientFD)
                    let request = try JSONDecoder().decode(ManagerControlRequest.self, from: data)
                    let response = handler(request)
                    try ManagerSocketIO.send(response, to: clientFD)
                } catch {
                    let response = ManagerControlResponse(ok: false, error: String(describing: error))
                    try? ManagerSocketIO.send(response, to: clientFD)
                }
            }
        }
    }
}

public final class ManagerControlClient {
    private let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func send(_ request: ManagerControlRequest) throws -> ManagerControlResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        try ManagerSocketIO.setUnixPath(socketPath, on: &addr)
        var connectAddr = addr
        let result = withUnsafePointer(to: &connectAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        if result != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
        }
        try ManagerSocketIO.send(request, to: fd)
        let data = try ManagerSocketIO.receiveAll(from: fd)
        return try JSONDecoder().decode(ManagerControlResponse.self, from: data)
    }
}
