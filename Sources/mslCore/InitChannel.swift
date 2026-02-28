import Foundation
import Darwin

public enum InitChannelErrorCode: String, Codable {
    case unsupportedVersion = "unsupported_version"
    case unsupportedOp = "unsupported_op"
    case invalidRequest = "invalid_request"
    case timeout
    case permissionDenied = "permission_denied"
    case resourceExhausted = "resource_exhausted"
    case internalError = "internal_error"
    case unavailable
}

public struct InitChannelErrorPayload: Codable {
    public var code: InitChannelErrorCode
    public var message: String

    public init(code: InitChannelErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

public struct InitChannelRequest: Codable {
    public var version: Int
    public var requestId: String
    public var op: String
    public var argv: [String]?
    public var envAdditions: [String: String]?
    public var cwd: String?
    public var hostShareRoot: String?
    public var timeoutMs: Int?
    public var ptyId: String?
    public var dataBase64: String?
    public var rows: Int?
    public var cols: Int?
    public var convergeUsername: String?
    public var convergeUID: Int?
    public var convergeGID: Int?
    public var convergeHome: String?
    public var convergePreferredShell: String?
    public var convergeFailOnUIDConflict: Bool?
    public var policyTemplateId: String?
    public var policyCommandFamily: String?
    public var policyAdminGroup: String?
    public var policySudoEnabled: Bool?
    public var policySudoRequireBinary: Bool?
    public var policySudoDropInPath: String?
    public var policySudoPasswordless: Bool?
    public var policySuEnabled: Bool?
    public var policySuPasswordless: Bool?
    public var policyShellFallbacks: [String]?
    public var policyWelcomeEnabled: Bool?
    public var policyWelcomeFrequency: String?
    public var policyWelcomeRespectHushlogin: Bool?
    public var policyWelcomeInstance: String?
    public var dnsMode: String?
    public var dnsNameservers: [String]?
    public var dnsSearchDomains: [String]?
    public var dnsResolverBackend: String?
    public var dnsSource: String?
    public var dnsProxyUpstreams: [String]?
    public var dnsProxyListenAddress: String?
    public var dnsProxyListenPort: Int?

    public init(
        version: Int = 1,
        requestId: String = UUID().uuidString,
        op: String,
        argv: [String]? = nil,
        envAdditions: [String: String]? = nil,
        cwd: String? = nil,
        hostShareRoot: String? = nil,
        timeoutMs: Int? = nil,
        ptyId: String? = nil,
        dataBase64: String? = nil,
        rows: Int? = nil,
        cols: Int? = nil,
        convergeUsername: String? = nil,
        convergeUID: Int? = nil,
        convergeGID: Int? = nil,
        convergeHome: String? = nil,
        convergePreferredShell: String? = nil,
        convergeFailOnUIDConflict: Bool? = nil,
        policyTemplateId: String? = nil,
        policyCommandFamily: String? = nil,
        policyAdminGroup: String? = nil,
        policySudoEnabled: Bool? = nil,
        policySudoRequireBinary: Bool? = nil,
        policySudoDropInPath: String? = nil,
        policySudoPasswordless: Bool? = nil,
        policySuEnabled: Bool? = nil,
        policySuPasswordless: Bool? = nil,
        policyShellFallbacks: [String]? = nil,
        policyWelcomeEnabled: Bool? = nil,
        policyWelcomeFrequency: String? = nil,
        policyWelcomeRespectHushlogin: Bool? = nil,
        policyWelcomeInstance: String? = nil,
        dnsMode: String? = nil,
        dnsNameservers: [String]? = nil,
        dnsSearchDomains: [String]? = nil,
        dnsResolverBackend: String? = nil,
        dnsSource: String? = nil,
        dnsProxyUpstreams: [String]? = nil,
        dnsProxyListenAddress: String? = nil,
        dnsProxyListenPort: Int? = nil
    ) {
        self.version = version
        self.requestId = requestId
        self.op = op
        self.argv = argv
        self.envAdditions = envAdditions
        self.cwd = cwd
        self.hostShareRoot = hostShareRoot
        self.timeoutMs = timeoutMs
        self.ptyId = ptyId
        self.dataBase64 = dataBase64
        self.rows = rows
        self.cols = cols
        self.convergeUsername = convergeUsername
        self.convergeUID = convergeUID
        self.convergeGID = convergeGID
        self.convergeHome = convergeHome
        self.convergePreferredShell = convergePreferredShell
        self.convergeFailOnUIDConflict = convergeFailOnUIDConflict
        self.policyTemplateId = policyTemplateId
        self.policyCommandFamily = policyCommandFamily
        self.policyAdminGroup = policyAdminGroup
        self.policySudoEnabled = policySudoEnabled
        self.policySudoRequireBinary = policySudoRequireBinary
        self.policySudoDropInPath = policySudoDropInPath
        self.policySudoPasswordless = policySudoPasswordless
        self.policySuEnabled = policySuEnabled
        self.policySuPasswordless = policySuPasswordless
        self.policyShellFallbacks = policyShellFallbacks
        self.policyWelcomeEnabled = policyWelcomeEnabled
        self.policyWelcomeFrequency = policyWelcomeFrequency
        self.policyWelcomeRespectHushlogin = policyWelcomeRespectHushlogin
        self.policyWelcomeInstance = policyWelcomeInstance
        self.dnsMode = dnsMode
        self.dnsNameservers = dnsNameservers
        self.dnsSearchDomains = dnsSearchDomains
        self.dnsResolverBackend = dnsResolverBackend
        self.dnsSource = dnsSource
        self.dnsProxyUpstreams = dnsProxyUpstreams
        self.dnsProxyListenAddress = dnsProxyListenAddress
        self.dnsProxyListenPort = dnsProxyListenPort
    }
}

public struct InitConvergeUserSpec {
    public var username: String
    public var uid: Int
    public var gid: Int
    public var home: String
    public var preferredShell: String?
    public var failOnUIDConflict: Bool

    public init(
        username: String,
        uid: Int,
        gid: Int,
        home: String,
        preferredShell: String? = nil,
        failOnUIDConflict: Bool = true
    ) {
        self.username = username
        self.uid = uid
        self.gid = gid
        self.home = home
        self.preferredShell = preferredShell
        self.failOnUIDConflict = failOnUIDConflict
    }
}

public struct InitChannelResponse: Codable {
    public var version: Int
    public var requestId: String
    public var op: String
    public var status: String
    public var error: InitChannelErrorPayload?
    public var exitCode: Int32?
    public var stdout: String?
    public var stderr: String?
    public var durationMs: Int?
    public var ptyId: String?
    public var dataBase64: String?
    public var meta: [String: String]?

    public var ok: Bool { status == "ok" }

    public init(
        version: Int = 1,
        requestId: String,
        op: String,
        status: String,
        error: InitChannelErrorPayload? = nil,
        exitCode: Int32? = nil,
        stdout: String? = nil,
        stderr: String? = nil,
        durationMs: Int? = nil,
        ptyId: String? = nil,
        dataBase64: String? = nil,
        meta: [String: String]? = nil
    ) {
        self.version = version
        self.requestId = requestId
        self.op = op
        self.status = status
        self.error = error
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.durationMs = durationMs
        self.ptyId = ptyId
        self.dataBase64 = dataBase64
        self.meta = meta
    }
}

public struct InitChannelProbeResult {
    public var version: Int?
    public var status: InitChannelHealth
    public var errorCode: String?
    public var errorMessage: String?

    public init(version: Int?, status: InitChannelHealth, errorCode: String?, errorMessage: String?) {
        self.version = version
        self.status = status
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }
}

/// File descriptor for a persistent vsock connection accepted from the guest.
/// The caller is responsible for keeping the underlying VZVirtioSocketConnection alive.
public final class InitChannelClient {
    private let socketPath: String
    private let handoffPath: String?
    private let ackPath: String?
    private let retryCount: Int
    private let retryDelayMs: Int
    private let timeoutMs: Int
    private let vsockFD: Int32?
    private let vsockLock = NSLock()

    public init(
        socketPath: String,
        handoffPath: String? = nil,
        ackPath: String? = nil,
        retryCount: Int = 10,
        retryDelayMs: Int = 100,
        timeoutMs: Int = 1_000,
        vsockFD: Int32? = nil
    ) {
        self.socketPath = socketPath
        self.handoffPath = handoffPath
        self.ackPath = ackPath
        self.retryCount = retryCount
        self.retryDelayMs = retryDelayMs
        self.timeoutMs = timeoutMs
        self.vsockFD = vsockFD
    }

    public func ping() throws -> InitChannelResponse {
        try send(InitChannelRequest(op: "ping", timeoutMs: timeoutMs))
    }

    public func convergeStatus() throws -> InitChannelResponse {
        try send(InitChannelRequest(op: "converge_status", timeoutMs: timeoutMs))
    }

    public func ptyOpen(
        argv: [String],
        cwd: String? = nil,
        rows: Int?,
        cols: Int?,
        timeoutMs: Int? = nil
    ) throws -> InitChannelResponse {
        try send(InitChannelRequest(
            op: "pty_open",
            argv: argv,
            cwd: cwd,
            timeoutMs: timeoutMs ?? self.timeoutMs,
            rows: rows,
            cols: cols
        ))
    }

    public func ptyRead(ptyId: String, timeoutMs: Int? = nil) throws -> InitChannelResponse {
        try send(InitChannelRequest(
            op: "pty_read",
            timeoutMs: timeoutMs ?? self.timeoutMs,
            ptyId: ptyId
        ))
    }

    public func ptyWrite(ptyId: String, data: Data, timeoutMs: Int? = nil) throws -> InitChannelResponse {
        try send(InitChannelRequest(
            op: "pty_write",
            timeoutMs: timeoutMs ?? self.timeoutMs,
            ptyId: ptyId,
            dataBase64: data.base64EncodedString()
        ))
    }

    public func ptyResize(ptyId: String, rows: Int, cols: Int, timeoutMs: Int? = nil) throws -> InitChannelResponse {
        try send(InitChannelRequest(
            op: "pty_resize",
            timeoutMs: timeoutMs ?? self.timeoutMs,
            ptyId: ptyId,
            rows: rows,
            cols: cols
        ))
    }

    public func ptyClose(ptyId: String, timeoutMs: Int? = nil) throws -> InitChannelResponse {
        try send(InitChannelRequest(
            op: "pty_close",
            timeoutMs: timeoutMs ?? self.timeoutMs,
            ptyId: ptyId
        ))
    }

    public func convergeUser(
        spec: InitConvergeUserSpec,
        policy: UserConvergencePolicy,
        instanceName: String,
        timeoutMs: Int? = nil
    ) throws -> InitChannelResponse {
        try send(InitChannelRequest(
            op: "converge_user",
            timeoutMs: timeoutMs ?? self.timeoutMs,
            convergeUsername: spec.username,
            convergeUID: spec.uid,
            convergeGID: spec.gid,
            convergeHome: spec.home,
            convergePreferredShell: spec.preferredShell,
            convergeFailOnUIDConflict: spec.failOnUIDConflict,
            policyTemplateId: policy.templateId,
            policyCommandFamily: policy.commandFamily,
            policyAdminGroup: policy.adminGroup,
            policySudoEnabled: policy.sudoPolicy.enabled,
            policySudoRequireBinary: policy.sudoPolicy.requireSudoBinary,
            policySudoDropInPath: policy.sudoPolicy.dropInPath,
            policySudoPasswordless: policy.sudoPolicy.passwordless,
            policySuEnabled: policy.suPolicy?.enabled,
            policySuPasswordless: policy.suPolicy?.passwordless,
            policyShellFallbacks: policy.shellFallbacks,
            policyWelcomeEnabled: policy.welcomePolicy.enabled,
            policyWelcomeFrequency: policy.welcomePolicy.frequency,
            policyWelcomeRespectHushlogin: policy.welcomePolicy.respectHushlogin,
            policyWelcomeInstance: instanceName
        ))
    }

    public func send(_ request: InitChannelRequest) throws -> InitChannelResponse {
        let effectiveTimeoutMs = request.timeoutMs ?? timeoutMs
        // Prefer persistent vsock, then file handoff, then Unix socket
        if let fd = vsockFD {
            return try sendViaPersistentVsock(request, fd: fd, effectiveTimeoutMs: effectiveTimeoutMs)
        }
        if let handoffPath, let ackPath {
            return try sendViaFileHandoff(
                request,
                handoffPath: handoffPath,
                ackPath: ackPath,
                effectiveTimeoutMs: effectiveTimeoutMs
            )
        }
        return try sendViaSocket(request, effectiveTimeoutMs: effectiveTimeoutMs)
    }

    private func sendViaPersistentVsock(
        _ request: InitChannelRequest,
        fd: Int32,
        effectiveTimeoutMs: Int
    ) throws -> InitChannelResponse {
        vsockLock.lock()
        defer { vsockLock.unlock() }

        var line = try encode(request)
        line.append(0x0A) // "\n"

        // Write with poll() to detect write stalls
        try line.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var remaining = raw.count
            var offset = 0
            while remaining > 0 {
                var wpfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let wready = poll(&wpfd, 1, 10_000) // 10s write timeout
                if wready == 0 {
                    throw MSLRuntimeError("vsock write timeout")
                }
                if wready < 0 {
                    if errno == EINTR { continue }
                    throw MSLRuntimeError("vsock write poll failed: \(lastErr())")
                }
                let n = write(fd, base + offset, remaining)
                if n < 0 {
                    throw MSLRuntimeError("vsock write failed: \(lastErr())")
                }
                offset += n
                remaining -= n
            }
        }

        // Read with poll() timeout since setsockopt(SO_RCVTIMEO) doesn't work on VZ fds.
        // Use 30s timeout to tolerate vsock latency spikes under heavy guest I/O (cloud-init).
        let readTimeoutMs: Int32
        if effectiveTimeoutMs <= 0 {
            readTimeoutMs = -1
        } else {
            readTimeoutMs = Int32(max(effectiveTimeoutMs, 30_000))
        }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            var rpfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let rready = poll(&rpfd, 1, readTimeoutMs)
            if rready == 0 {
                throw MSLRuntimeError("vsock read timeout (\(readTimeoutMs)ms) for op=\(request.op)")
            }
            if rready < 0 {
                if errno == EINTR { continue }
                throw MSLRuntimeError("vsock read poll failed: \(lastErr())")
            }
            // Check for error/hangup conditions returned by the kernel
            let revents = rpfd.revents
            if (revents & Int16(POLLHUP)) != 0 || (revents & Int16(POLLERR)) != 0 {
                // Peer closed or transport error — try one read to get EOF or error
                let n = read(fd, &chunk, chunk.count)
                if n <= 0 {
                    throw MSLRuntimeError("vsock connection lost (revents=\(revents)) for op=\(request.op)")
                }
                // Got data despite HUP (possible with buffered data), process it
                buffer.append(chunk, count: n)
                if chunk[..<n].contains(0x0A) { break }
                continue
            }

            let n = read(fd, &chunk, chunk.count)
            if n == 0 {
                throw MSLRuntimeError("vsock connection closed by guest")
            }
            if n < 0 {
                throw MSLRuntimeError("vsock read failed: \(lastErr())")
            }
            buffer.append(chunk, count: n)
            if chunk[..<n].contains(0x0A) {
                break
            }
        }

        guard let lineData = buffer.split(separator: 0x0A, maxSplits: 1, omittingEmptySubsequences: true).first else {
            throw MSLRuntimeError("empty vsock response")
        }
        return try decode(Data(lineData))
    }

    private func sendViaSocket(_ request: InitChannelRequest, effectiveTimeoutMs: Int) throws -> InitChannelResponse {
        let fd = try connectWithRetry()
        defer { close(fd) }
        try configureTimeout(fd, effectiveTimeoutMs: effectiveTimeoutMs)

        var line = try encode(request)
        line.append(0x0A) // "\n"
        try line.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            if write(fd, base, raw.count) < 0 {
                throw MSLRuntimeError("init channel write failed: \(lastErr())")
            }
        }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n == 0 {
                break
            }
            if n < 0 {
                if errno == EWOULDBLOCK || errno == EAGAIN {
                    throw MSLRuntimeError("init channel timeout", exitCode: 1)
                }
                throw MSLRuntimeError("init channel read failed: \(lastErr())")
            }
            buffer.append(chunk, count: n)
            if chunk.contains(0x0A) {
                break
            }
        }

        guard let lineData = buffer.split(separator: 0x0A, maxSplits: 1, omittingEmptySubsequences: true).first else {
            throw MSLRuntimeError("invalid init channel response")
        }
        return try decode(Data(lineData))
    }

    private func sendViaFileHandoff(
        _ request: InitChannelRequest,
        handoffPath: String,
        ackPath: String,
        effectiveTimeoutMs: Int
    ) throws -> InitChannelResponse {
        let fm = FileManager.default
        let handoffURL = URL(fileURLWithPath: handoffPath)
        let ackURL = URL(fileURLWithPath: ackPath)
        try fm.createDirectory(at: handoffURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let payload = try encode(request)
        try payload.write(to: handoffURL, options: .atomic)

        let deadline: Int64 = effectiveTimeoutMs > 0 ? nowEpochMs() + Int64(effectiveTimeoutMs) : Int64.max
        var lastAckRequestID: String?
        var ackDecodeError: String?
        while nowEpochMs() <= deadline {
            if fm.fileExists(atPath: ackURL.path) {
                do {
                    let data = try Data(contentsOf: ackURL)
                    let response = try decode(data)
                    lastAckRequestID = response.requestId
                    if response.requestId == request.requestId {
                        return response
                    }
                } catch {
                    ackDecodeError = String(describing: error)
                }
            }
            usleep(50_000)
        }
        let handoffExists = fm.fileExists(atPath: handoffURL.path)
        let ackExists = fm.fileExists(atPath: ackURL.path)
        throw MSLRuntimeError(
            "init channel timeout via file handoff " +
            "(handoff=\(handoffPath), ack=\(ackPath), handoff_exists=\(handoffExists), " +
            "ack_exists=\(ackExists), ack_request_id=\(lastAckRequestID ?? "none"), " +
            "ack_decode_error=\(ackDecodeError ?? "none"))"
        )
    }

    private func connectWithRetry() throws -> Int32 {
        for attempt in 0..<retryCount {
            do {
                return try connectOnce()
            } catch {
                if attempt == retryCount - 1 {
                    throw MSLRuntimeError("init channel unavailable at \(socketPath)")
                }
                usleep(useconds_t(retryDelayMs * 1000))
            }
        }
        throw MSLRuntimeError("init channel unavailable at \(socketPath)")
    }

    private func connectOnce() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 {
            throw MSLRuntimeError("failed to create init channel socket: \(lastErr())")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        if pathBytes.count >= MemoryLayout.size(ofValue: addr.sun_path) {
            close(fd)
            throw MSLRuntimeError("init channel socket path too long")
        }

        _ = withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (idx, byte) in pathBytes.enumerated() {
                raw[idx] = byte
            }
        }

        let len = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fd, sockaddrPtr, len)
            }
        }
        if connectResult != 0 {
            close(fd)
            throw MSLRuntimeError("init channel unavailable at \(socketPath)")
        }
        return fd
    }

    private func configureTimeout(_ fd: Int32, effectiveTimeoutMs: Int) throws {
        // 0 means no timeout (block until response).
        var tv = timeval(
            tv_sec: time_t(effectiveTimeoutMs / 1000),
            tv_usec: suseconds_t((effectiveTimeoutMs % 1000) * 1000)
        )
        if setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size)) != 0 {
            throw MSLRuntimeError("init channel socket timeout setup failed")
        }
        if setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size)) != 0 {
            throw MSLRuntimeError("init channel socket timeout setup failed")
        }
    }

    public func encode(_ request: InitChannelRequest) throws -> Data {
        try JSONEncoder().encode(request)
    }

    public func decode(_ data: Data) throws -> InitChannelResponse {
        try JSONDecoder().decode(InitChannelResponse.self, from: data)
    }
}

private func lastErr() -> String {
    String(cString: strerror(errno))
}
