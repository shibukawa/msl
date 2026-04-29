import Foundation
import Darwin

final class InitRelayPortForwardingManager: PortForwardingBackend {
    private struct ActiveListener {
        var listener: InitRelayPortListener
        var mapping: PortMapping
    }

    private let logger: MSLLogger
    private let initClient: InitChannelClient
    private let lock = NSLock()
    private var active: [Int: ActiveListener] = [:]
    private var errors: [Int: String] = [:]

    init(logger: MSLLogger, initClient: InitChannelClient) {
        self.logger = logger
        self.initClient = initClient
    }

    @discardableResult
    func sync(mappings: [PortMapping]) -> RuntimeControlResponse {
        lock.lock()
        defer { lock.unlock() }

        let wanted = Set(mappings.map { $0.hostPort })
        for (hostPort, existing) in active where !wanted.contains(hostPort) {
            existing.listener.stop()
            active.removeValue(forKey: hostPort)
            errors.removeValue(forKey: hostPort)
        }

        for mapping in mappings {
            if let existing = active[mapping.hostPort], existing.mapping == mapping {
                continue
            }
            if let existing = active[mapping.hostPort] {
                existing.listener.stop()
                active.removeValue(forKey: mapping.hostPort)
            }
            do {
                let listener = InitRelayPortListener(
                    bindHost: mapping.bindAddress,
                    bindPort: mapping.hostPort,
                    targetPort: mapping.guestPort,
                    initClient: initClient,
                    logger: logger
                )
                try listener.start()
                active[mapping.hostPort] = ActiveListener(listener: listener, mapping: mapping)
                errors.removeValue(forKey: mapping.hostPort)
                logger.log("init_relay_port_forward_listener_started", fields: [
                    "hostPort": String(mapping.hostPort),
                    "guestPort": String(mapping.guestPort)
                ])
            } catch {
                let message = String(describing: error)
                errors[mapping.hostPort] = message
                logger.log("init_relay_port_forward_bind_failed", fields: [
                    "hostPort": String(mapping.hostPort),
                    "guestPort": String(mapping.guestPort),
                    "error": message
                ])
            }
        }

        let items = mappings.sorted { $0.hostPort < $1.hostPort }.map { mapping in
            RuntimePortStatusItem(
                instance: mapping.instance,
                hostPort: mapping.hostPort,
                guestPort: mapping.guestPort,
                bindAddress: mapping.bindAddress,
                source: mapping.source,
                active: active[mapping.hostPort] != nil,
                ownerInstance: nil,
                guestAddress: nil,
                localhostEndpoint: "\(mapping.bindAddress):\(mapping.hostPort)",
                hostnameEndpoint: nil,
                directEndpoint: nil,
                error: errors[mapping.hostPort]
            )
        }
        return RuntimeControlResponse(ok: true, error: nil, items: items)
    }

    func add(_ mapping: PortMapping) -> RuntimeControlResponse {
        lock.lock()
        let mappings = active.values.map(\.mapping).filter { $0.hostPort != mapping.hostPort } + [mapping]
        lock.unlock()
        return sync(mappings: mappings)
    }

    func remove(hostPort: Int, ownerInstance: String) -> RuntimeControlResponse {
        lock.lock()
        let mappings = active.values.map(\.mapping).filter { mapping in
            if mapping.hostPort != hostPort {
                return true
            }
            return mapping.instance != ownerInstance
        }
        lock.unlock()
        return sync(mappings: mappings)
    }

    func list(mappings: [PortMapping]) -> RuntimeControlResponse {
        sync(mappings: mappings)
    }

    func stopAll() {
        lock.lock()
        defer { lock.unlock() }
        for (_, existing) in active {
            existing.listener.stop()
        }
        active.removeAll()
        errors.removeAll()
    }
}

private final class InitRelayPortListener {
    private struct BoundListener {
        var fd: Int32
        var host: String
    }

    private let bindHost: String
    private let bindPort: Int
    private let targetPort: Int
    private let initClient: InitChannelClient
    private let logger: MSLLogger
    private var listeners: [BoundListener] = []
    private var acceptThreads: [Thread] = []
    private var running = false

    init(
        bindHost: String,
        bindPort: Int,
        targetPort: Int,
        initClient: InitChannelClient,
        logger: MSLLogger
    ) {
        self.bindHost = bindHost
        self.bindPort = bindPort
        self.targetPort = targetPort
        self.initClient = initClient
        self.logger = logger
    }

    func start() throws {
        if running { return }

        var created: [BoundListener] = []
        do {
            for host in expandedBindHosts(for: bindHost) {
                created.append(try makeListener(host: host))
            }
        } catch {
            for listener in created {
                _ = close(listener.fd)
            }
            throw error
        }

        running = true
        listeners = created
        acceptThreads = created.map { listener in
            let thread = Thread { [weak self] in
                self?.acceptLoop(listenerFD: listener.fd)
            }
            thread.name = "msl.init-relay-port.\(bindPort).\(listener.host)"
            thread.start()
            return thread
        }
    }

    func stop() {
        guard running else { return }
        running = false
        for listener in listeners {
            _ = shutdown(listener.fd, SHUT_RDWR)
            _ = close(listener.fd)
        }
        listeners.removeAll()
        acceptThreads.removeAll()
    }

    private func acceptLoop(listenerFD: Int32) {
        while running {
            let client = accept(listenerFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                if running { usleep(30_000) }
                continue
            }
            Thread.detachNewThread {
                self.handleClient(clientFD: client)
                _ = close(client)
            }
        }
    }

    private func handleClient(clientFD: Int32) {
        do {
            let relayClient = initClient.makeSidebandClient()
            let writeClient = initClient.makeSidebandClient()
            let procId = try openRelayProcess(client: relayClient)
            let inputClosed = RelayFlag()
            let inputThread = Thread {
                self.pumpSocketToProc(clientFD: clientFD, client: writeClient, procId: procId, closed: inputClosed)
            }
            inputThread.name = "msl.init-relay-port.\(bindPort).stdin"
            inputThread.start()

            try pumpProcToSocket(client: relayClient, procId: procId, clientFD: clientFD, inputClosed: inputClosed)
        } catch {
            lingerReset(fd: clientFD)
            logger.log("init_relay_port_forward_connection_failed", fields: [
                "hostPort": String(bindPort),
                "guestPort": String(targetPort),
                "error": String(describing: error)
            ])
        }
    }

    private func openRelayProcess(client: InitChannelClient) throws -> String {
        let script = """
        i=0
        while [ "$i" -lt 50 ]; do
          /bin/busybox nc 127.0.0.1 \(targetPort) && exit $?
          i=$((i + 1))
          sleep 0.1
        done
        exit 1
        """
        let response = try client.procOpen(
            argv: ["/bin/sh", "-lc", script],
            runAsRoot: true,
            timeoutMs: 5_000
        )
        guard response.ok, let procId = response.procId else {
            throw MSLRuntimeError(response.error?.message ?? "init relay proc_open failed")
        }
        return procId
    }

    private func pumpSocketToProc(clientFD: Int32, client: InitChannelClient, procId: String, closed: RelayFlag) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(clientFD, &buffer, buffer.count)
            if n > 0 {
                let data = Data(buffer[0..<Int(n)])
                do {
                    let response = try client.procWrite(procId: procId, data: data, timeoutMs: 10_000)
                    if !response.ok {
                        break
                    }
                } catch {
                    break
                }
                continue
            }
            if n < 0 && errno == EINTR {
                continue
            }
            _ = try? client.procStdinClose(procId: procId, timeoutMs: 1_000)
            closed.set()
            return
        }
        closed.set()
    }

    private func pumpProcToSocket(
        client: InitChannelClient,
        procId: String,
        clientFD: Int32,
        inputClosed: RelayFlag
    ) throws {
        while true {
            let response = try client.procRead(procId: procId, timeoutMs: 500)
            guard response.ok else {
                throw MSLRuntimeError(response.error?.message ?? "init relay proc_read failed")
            }

            var wroteOutput = false
            for chunk in response.chunks ?? [] {
                guard chunk.stream == "stdout", let data = chunk.rawData, !data.isEmpty else {
                    continue
                }
                if !writeAll(fd: clientFD, data: data) {
                    _ = try? client.procStdinClose(procId: procId, timeoutMs: 1_000)
                    return
                }
                wroteOutput = true
            }

            if response.exitCode != nil {
                return
            }
            if !wroteOutput && inputClosed.value {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
    }

    private func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return true
            }
            var offset = 0
            while offset < rawBuffer.count {
                let written = write(fd, base.advanced(by: offset), rawBuffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if written == 0 {
                    return false
                }
                offset += written
            }
            return true
        }
    }

    private func lingerReset(fd: Int32) {
        var linger = linger(l_onoff: 1, l_linger: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<linger>.size))
    }

    private func expandedBindHosts(for bindHost: String) -> [String] {
        switch bindHost {
        case "127.0.0.1":
            return ["127.0.0.1", "::1"]
        case "0.0.0.0":
            return ["0.0.0.0", "::"]
        default:
            return [bindHost]
        }
    }

    private func makeListener(host: String) throws -> BoundListener {
        if host.contains(":") {
            return try makeIPv6Listener(host: host)
        }
        return try makeIPv4Listener(host: host)
    }

    private func makeIPv4Listener(host: String) throws -> BoundListener {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 {
            throw MSLRuntimeError("listen socket create failed for \(host): \(lastErr())")
        }

        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(bindPort).bigEndian)
        if inet_pton(AF_INET, host, &addr.sin_addr) != 1 {
            _ = close(fd)
            throw MSLRuntimeError("invalid bind host: \(host)")
        }
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindResult != 0 {
            let error = lastErr()
            _ = close(fd)
            throw MSLRuntimeError("bind failed for \(host):\(bindPort): \(error)")
        }
        if listen(fd, 16) != 0 {
            let error = lastErr()
            _ = close(fd)
            throw MSLRuntimeError("listen failed for \(host):\(bindPort): \(error)")
        }
        return BoundListener(fd: fd, host: host)
    }

    private func makeIPv6Listener(host: String) throws -> BoundListener {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        if fd < 0 {
            throw MSLRuntimeError("listen socket create failed for \(host): \(lastErr())")
        }

        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = in_port_t(UInt16(bindPort).bigEndian)
        if inet_pton(AF_INET6, host, &addr.sin6_addr) != 1 {
            _ = close(fd)
            throw MSLRuntimeError("invalid bind host: \(host)")
        }
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        if bindResult != 0 {
            let error = lastErr()
            _ = close(fd)
            throw MSLRuntimeError("bind failed for \(host):\(bindPort): \(error)")
        }
        if listen(fd, 16) != 0 {
            let error = lastErr()
            _ = close(fd)
            throw MSLRuntimeError("listen failed for \(host):\(bindPort): \(error)")
        }
        return BoundListener(fd: fd, host: host)
    }

    private func lastErr() -> String {
        String(cString: strerror(errno))
    }
}

private final class RelayFlag {
    private let lock = NSLock()
    private var _value = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func set() {
        lock.lock()
        _value = true
        lock.unlock()
    }
}
