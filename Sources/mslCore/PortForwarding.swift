import Foundation
import Darwin

final class PortForwardingManager {
    private struct ActiveListener {
        var listener: PortListener
        var mapping: PortMapping
    }

    private let logger: MSLLogger
    private let guestIPResolver: GuestIPResolver
    private let exposeVMNetEndpoints: Bool
    private let lock = NSLock()
    private var active: [Int: ActiveListener] = [:]
    private var errors: [Int: String] = [:]

    init(logger: MSLLogger, guestIPResolver: GuestIPResolver, exposeVMNetEndpoints: Bool) {
        self.logger = logger
        self.guestIPResolver = guestIPResolver
        self.exposeVMNetEndpoints = exposeVMNetEndpoints
    }

    func updateGuestIP(_ ip: String?) {
        guestIPResolver.updateGuestIP(ip)
    }

    func add(_ mapping: PortMapping) -> RuntimeControlResponse {
        lock.lock()
        defer { lock.unlock() }

        if let existing = active[mapping.hostPort], existing.mapping.guestPort == mapping.guestPort {
            if existing.mapping.instance != mapping.instance {
                let message = portConflictMessage(hostPort: mapping.hostPort, ownerInstance: existing.mapping.instance)
                return RuntimeControlResponse(
                    ok: false,
                    error: message,
                    items: snapshotWithProposedLocked(mapping, error: message, ownerInstance: existing.mapping.instance)
                )
            }
            return RuntimeControlResponse(ok: true, error: nil, items: snapshotCurrentLocked())
        }

        if let existing = active[mapping.hostPort] {
            if existing.mapping.instance != mapping.instance {
                let message = portConflictMessage(hostPort: mapping.hostPort, ownerInstance: existing.mapping.instance)
                return RuntimeControlResponse(
                    ok: false,
                    error: message,
                    items: snapshotWithProposedLocked(mapping, error: message, ownerInstance: existing.mapping.instance)
                )
            }
            existing.listener.stop()
            active.removeValue(forKey: mapping.hostPort)
        }

        do {
            let listener = try PortListener(
                bindHost: mapping.bindAddress,
                bindPort: mapping.hostPort,
                guestIPResolver: guestIPResolver,
                targetPort: mapping.guestPort
            )
            try listener.start()
            active[mapping.hostPort] = ActiveListener(listener: listener, mapping: mapping)
            errors.removeValue(forKey: mapping.hostPort)
            logger.log("port_forward_listener_started", fields: [
                "hostPort": String(mapping.hostPort),
                "guestPort": String(mapping.guestPort),
                "targetCandidates": guestIPResolver.candidateIPs().joined(separator: ",")
            ])
            return RuntimeControlResponse(ok: true, error: nil, items: snapshotCurrentLocked())
        } catch {
            let message = formatBindError(error, mapping: mapping)
            errors[mapping.hostPort] = message
            logger.log("port_forward_bind_failed", fields: [
                "hostPort": String(mapping.hostPort),
                "guestPort": String(mapping.guestPort),
                "error": message
            ])
            return RuntimeControlResponse(ok: false, error: message, items: snapshotWithProposedLocked(mapping))
        }
    }

    func remove(hostPort: Int) -> RuntimeControlResponse {
        lock.lock()
        defer { lock.unlock() }

        if let existing = active.removeValue(forKey: hostPort) {
            existing.listener.stop()
            logger.log("port_forward_listener_stopped", fields: ["hostPort": String(hostPort)])
        }
        errors.removeValue(forKey: hostPort)
        return RuntimeControlResponse(ok: true, error: nil, items: snapshotCurrentLocked())
    }

    func remove(hostPort: Int, ownerInstance: String) -> RuntimeControlResponse {
        lock.lock()
        defer { lock.unlock() }

        if let existing = active[hostPort], existing.mapping.instance != ownerInstance {
            let message = portConflictMessage(hostPort: hostPort, ownerInstance: existing.mapping.instance)
            return RuntimeControlResponse(ok: false, error: message, items: snapshotCurrentLocked())
        }
        if let existing = active.removeValue(forKey: hostPort) {
            existing.listener.stop()
            logger.log("port_forward_listener_stopped", fields: ["hostPort": String(hostPort)])
        }
        errors.removeValue(forKey: hostPort)
        return RuntimeControlResponse(ok: true, error: nil, items: snapshotCurrentLocked())
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
                let listener = try PortListener(
                    bindHost: mapping.bindAddress,
                    bindPort: mapping.hostPort,
                    guestIPResolver: guestIPResolver,
                    targetPort: mapping.guestPort
                )
                try listener.start()
                active[mapping.hostPort] = ActiveListener(listener: listener, mapping: mapping)
                errors.removeValue(forKey: mapping.hostPort)
            } catch {
                let message = formatBindError(error, mapping: mapping)
                errors[mapping.hostPort] = message
                logger.log("port_forward_bind_failed", fields: [
                    "hostPort": String(mapping.hostPort),
                    "guestPort": String(mapping.guestPort),
                    "error": message
                ])
            }
        }
        return RuntimeControlResponse(ok: true, error: nil, items: snapshotFromMappingsLocked(mappings))
    }

    func list(mappings: [PortMapping]) -> RuntimeControlResponse {
        lock.lock()
        defer { lock.unlock() }
        return RuntimeControlResponse(ok: true, error: nil, items: snapshotFromMappingsLocked(mappings))
    }

    func stopAll() {
        lock.lock()
        defer { lock.unlock() }
        for (_, existing) in active {
            existing.listener.stop()
        }
        active.removeAll()
    }

    private func snapshotWithProposedLocked(
        _ proposed: PortMapping? = nil,
        error proposedError: String? = nil,
        ownerInstance: String? = nil
    ) -> [RuntimePortStatusItem] {
        var map = active.mapValues { $0.mapping }
        if let proposed {
            map[proposed.hostPort] = proposed
        }
        let mappings = map.values.sorted { $0.hostPort < $1.hostPort }
        let externalErrors: [Int: String]
        if let proposed, let proposedError {
            externalErrors = [proposed.hostPort: proposedError]
        } else {
            externalErrors = [:]
        }
        let ownerOverrides: [Int: String]
        if let proposed, let ownerInstance {
            ownerOverrides = [proposed.hostPort: ownerInstance]
        } else {
            ownerOverrides = [:]
        }
        return snapshotFromMappingsLocked(
            mappings,
            externalErrors: externalErrors,
            ownerOverrides: ownerOverrides
        )
    }

    private func snapshotCurrentLocked() -> [RuntimePortStatusItem] {
        let mappings = active.values.map { $0.mapping }.sorted { $0.hostPort < $1.hostPort }
        return snapshotFromMappingsLocked(mappings)
    }

    private func snapshotFromMappingsLocked(
        _ mappings: [PortMapping],
        externalErrors: [Int: String] = [:],
        ownerOverrides: [Int: String] = [:]
    ) -> [RuntimePortStatusItem] {
        let source: [PortMapping]
        source = mappings.sorted { $0.hostPort < $1.hostPort }
        let guestAddress = exposeVMNetEndpoints ? guestIPResolver.preferredGuestIPHint() : nil
        return source.map { mapping in
            let localhostEndpoint = "\(mapping.bindAddress):\(mapping.hostPort)"
            let hostnameEndpoint: String?
            if exposeVMNetEndpoints, mapping.bindAddress == "127.0.0.1" {
                hostnameEndpoint = "\(NetworkIdentity.serviceHostname(for: mapping.instance)):\(mapping.hostPort)"
            } else {
                hostnameEndpoint = nil
            }
            let directEndpoint = guestAddress.map { "\($0):\(mapping.guestPort)" }
            return RuntimePortStatusItem(
                instance: mapping.instance,
                hostPort: mapping.hostPort,
                guestPort: mapping.guestPort,
                bindAddress: mapping.bindAddress,
                source: mapping.source,
                active: active[mapping.hostPort] != nil,
                ownerInstance: ownerOverrides[mapping.hostPort],
                guestAddress: guestAddress,
                localhostEndpoint: localhostEndpoint,
                hostnameEndpoint: hostnameEndpoint,
                directEndpoint: directEndpoint,
                error: externalErrors[mapping.hostPort] ?? errors[mapping.hostPort]
            )
        }
    }

    private func formatBindError(_ error: Error, mapping: PortMapping) -> String {
        let message = String(describing: error)
        guard exposeVMNetEndpoints,
              message.localizedCaseInsensitiveContains("address already in use"),
              let guestIPHint = guestIPResolver.preferredGuestIPHint() else {
            return message
        }
        return "\(message). host port is busy; use \(guestIPHint):\(mapping.guestPort) directly."
    }

    private func portConflictMessage(hostPort: Int, ownerInstance: String) -> String {
        "port_conflict host_port=\(hostPort) owner_instance=\(ownerInstance)"
    }
}

private final class PortListener {
    private struct BoundListener {
        var fd: Int32
        var host: String
    }

    private let bindHost: String
    private let bindPort: Int
    private let guestIPResolver: GuestIPResolver
    private let targetPort: Int
    private var listeners: [BoundListener] = []
    private var acceptThreads: [Thread] = []
    private var running = false

    init(bindHost: String, bindPort: Int, guestIPResolver: GuestIPResolver, targetPort: Int) throws {
        self.bindHost = bindHost
        self.bindPort = bindPort
        self.guestIPResolver = guestIPResolver
        self.targetPort = targetPort
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
            thread.name = "msl.port.\(bindPort).\(listener.host)"
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
        let (targetFD, selectedIP) = connectTarget()
        if targetFD < 0 {
            return
        }
        if let selectedIP {
            guestIPResolver.reportSuccess(ip: selectedIP)
        }
        defer { _ = close(targetFD) }
        bridge(clientFD: clientFD, targetFD: targetFD)
    }

    private func connectTarget() -> (Int32, String?) {
        let candidates = guestIPResolver.candidateIPs()
        for ip in candidates {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            if fd < 0 { continue }
            if connectWithTimeout(fd: fd, host: ip, port: targetPort, timeoutMs: 150) {
                return (fd, ip)
            }
            _ = close(fd)
        }
        return (-1, nil)
    }

    private func connectWithTimeout(fd: Int32, host: String, port: Int, timeoutMs: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL, 0)
        if flags < 0 { return false }
        if fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0 {
            return false
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        if inet_pton(AF_INET, host, &addr.sin_addr) != 1 {
            return false
        }
        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connectResult == 0 {
            _ = fcntl(fd, F_SETFL, flags)
            return true
        }
        if errno != EINPROGRESS {
            _ = fcntl(fd, F_SETFL, flags)
            return false
        }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let pollResult = poll(&pfd, 1, timeoutMs)
        if pollResult <= 0 {
            _ = fcntl(fd, F_SETFL, flags)
            return false
        }

        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        if getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len) != 0 || soError != 0 {
            _ = fcntl(fd, F_SETFL, flags)
            return false
        }
        _ = fcntl(fd, F_SETFL, flags)
        return true
    }

    private func bridge(clientFD: Int32, targetFD: Int32) {
        var openClient = true
        var openTarget = true
        var fds = [
            pollfd(fd: clientFD, events: Int16(POLLIN), revents: 0),
            pollfd(fd: targetFD, events: Int16(POLLIN), revents: 0)
        ]

        while openClient || openTarget {
            fds[0].events = openClient ? Int16(POLLIN) : 0
            fds[1].events = openTarget ? Int16(POLLIN) : 0
            let ready = poll(&fds, nfds_t(fds.count), 500)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { continue }

            if openClient && (fds[0].revents & Int16(POLLIN)) != 0 {
                openClient = pump(from: clientFD, to: targetFD)
            }
            if openTarget && (fds[1].revents & Int16(POLLIN)) != 0 {
                openTarget = pump(from: targetFD, to: clientFD)
            }
            if (fds[0].revents & Int16(POLLHUP)) != 0 { openClient = false }
            if (fds[1].revents & Int16(POLLHUP)) != 0 { openTarget = false }
        }
    }

    private func pump(from srcFD: Int32, to dstFD: Int32) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 8192)
        let n = read(srcFD, &buffer, buffer.count)
        if n <= 0 { return false }
        var written = 0
        while written < n {
            let w = buffer.withUnsafeBytes { rawPtr -> Int in
                let base = rawPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                return write(dstFD, base.advanced(by: written), Int(n - written))
            }
            if w < 0 {
                if errno == EINTR { continue }
                return false
            }
            written += w
        }
        return true
    }

    private func lastErr() -> String {
        String(cString: strerror(errno))
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
}
