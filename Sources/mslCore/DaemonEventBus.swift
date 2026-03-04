import Foundation
import Darwin

struct DaemonEventEnvelope: Codable {
    var seq: Int64
    var topic: String
    var type: String
    var instance: String?
    var state: String?
    var epochMs: Int64
    var meta: [String: String]?
}

private struct DaemonEventSubscribeRequest: Codable {
    var op: String
    var topics: [String]?
}

private struct EventSubscriber {
    var fd: Int32
    var topics: Set<String>
}

final class DaemonEventBus {
    private let socketPath: String
    private let logger: MSLLogger
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false
    private var acceptThread: Thread?
    private var subscribers: [Int32: EventSubscriber] = [:]
    private var nextSeq: Int64 = 0

    init(socketPath: String, logger: MSLLogger) {
        self.socketPath = socketPath
        self.logger = logger
    }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        if running {
            return
        }
        try removeSocketIfExists()

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        if listenFD < 0 {
            throw MSLRuntimeError("failed to create event socket: \(lastErr())")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        if pathBytes.count >= MemoryLayout.size(ofValue: addr.sun_path) {
            throw MSLRuntimeError("event socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.initializeMemory(as: CChar.self, repeating: 0)
            for (index, value) in pathBytes.enumerated() {
                raw[index] = value
            }
        }

        let addrLen = socklen_t(MemoryLayout.size(ofValue: addr))
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, addrLen)
            }
        }
        if bindResult != 0 {
            throw MSLRuntimeError("failed to bind event socket: \(lastErr())")
        }
        if listen(listenFD, 16) != 0 {
            throw MSLRuntimeError("failed to listen event socket: \(lastErr())")
        }

        running = true
        let thread = Thread { [weak self] in
            self?.acceptLoop()
        }
        thread.name = "msl.runtime.events"
        thread.start()
        acceptThread = thread
    }

    func stop() {
        lock.lock()
        if !running {
            lock.unlock()
            return
        }
        running = false
        let fd = listenFD
        listenFD = -1
        let subscriberFDs = Array(subscribers.keys)
        subscribers.removeAll()
        lock.unlock()

        if fd >= 0 {
            _ = shutdown(fd, SHUT_RDWR)
            _ = close(fd)
        }
        for subFD in subscriberFDs {
            _ = shutdown(subFD, SHUT_RDWR)
            _ = close(subFD)
        }
        try? removeSocketIfExists()
    }

    func publish(topic: String, type: String, instance: String?, state: String?, meta: [String: String]? = nil) {
        let envelope = lock.withLock { () -> DaemonEventEnvelope in
            nextSeq += 1
            return DaemonEventEnvelope(
                seq: nextSeq,
                topic: topic,
                type: type,
                instance: instance,
                state: state,
                epochMs: nowEpochMs(),
                meta: meta
            )
        }

        guard var payload = try? JSONEncoder().encode(envelope) else {
            return
        }
        payload.append(UInt8(ascii: "\n"))

        var staleFDs: [Int32] = []
        lock.lock()
        let current = subscribers.values
        for subscriber in current {
            if !subscriber.topics.isEmpty && !subscriber.topics.contains(topic) {
                continue
            }
            let wrote = payload.withUnsafeBytes { raw in
                write(subscriber.fd, raw.baseAddress, raw.count)
            }
            if wrote <= 0 {
                staleFDs.append(subscriber.fd)
            }
        }
        for fd in staleFDs {
            subscribers.removeValue(forKey: fd)
        }
        lock.unlock()

        for fd in staleFDs {
            _ = shutdown(fd, SHUT_RDWR)
            _ = close(fd)
        }
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let isRunning = running
            let fd = listenFD
            lock.unlock()
            if !isRunning || fd < 0 {
                break
            }

            let clientFD = accept(fd, nil, nil)
            if clientFD < 0 {
                if errno == EINTR {
                    continue
                }
                if isRunning {
                    usleep(50_000)
                }
                continue
            }

            let thread = Thread { [weak self] in
                self?.handleClient(fd: clientFD)
            }
            thread.name = "msl.runtime.event.client"
            thread.start()
        }
    }

    private func handleClient(fd: Int32) {
        defer {
            lock.lock()
            let hadSubscriber = subscribers.removeValue(forKey: fd) != nil
            lock.unlock()
            if hadSubscriber {
                logger.log("daemon_event_subscriber_disconnected")
            }
            _ = shutdown(fd, SHUT_RDWR)
            _ = close(fd)
        }

        guard let request = readSubscribeRequest(fd: fd), request.op == "subscribe" else {
            return
        }
        let topics = Set((request.topics ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        lock.lock()
        subscribers[fd] = EventSubscriber(fd: fd, topics: topics)
        lock.unlock()
        logger.log("daemon_event_subscriber_connected", fields: ["topics": topics.sorted().joined(separator: ",")])

        // Keep connection alive and watch for disconnect.
        var buffer = [UInt8](repeating: 0, count: 256)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 {
                break
            }
        }
    }

    private func readSubscribeRequest(fd: Int32) -> DaemonEventSubscribeRequest? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 1024)
        while buffer.count < 8 * 1024 {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 {
                return nil
            }
            buffer.append(chunk, count: n)
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[..<newline]
                return try? JSONDecoder().decode(DaemonEventSubscribeRequest.self, from: line)
            }
        }
        return nil
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

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
