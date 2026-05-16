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
    public var runAsRoot: Bool?
    public var cwd: String?
    public var hostShareRoot: String?
    public var timeoutMs: Int?
    public var ptyId: String?
    public var procId: String?
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
    public var initSourcePath: String?
    public var initDryRun: Bool?
    public var sidebandRole: String?
    public var displayName: String?
    public var displayPort: Int?
    public var runtimeDir: String?

    public init(
        version: Int = 1,
        requestId: String = UUID().uuidString,
        op: String,
        argv: [String]? = nil,
        envAdditions: [String: String]? = nil,
        runAsRoot: Bool? = nil,
        cwd: String? = nil,
        hostShareRoot: String? = nil,
        timeoutMs: Int? = nil,
        ptyId: String? = nil,
        procId: String? = nil,
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
        dnsProxyListenPort: Int? = nil,
        initSourcePath: String? = nil,
        initDryRun: Bool? = nil,
        sidebandRole: String? = nil,
        displayName: String? = nil,
        displayPort: Int? = nil,
        runtimeDir: String? = nil
    ) {
        self.version = version
        self.requestId = requestId
        self.op = op
        self.argv = argv
        self.envAdditions = envAdditions
        self.runAsRoot = runAsRoot
        self.cwd = cwd
        self.hostShareRoot = hostShareRoot
        self.timeoutMs = timeoutMs
        self.ptyId = ptyId
        self.procId = procId
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
        self.initSourcePath = initSourcePath
        self.initDryRun = initDryRun
        self.sidebandRole = sidebandRole
        self.displayName = displayName
        self.displayPort = displayPort
        self.runtimeDir = runtimeDir
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
    public var procId: String?
    public var dataBase64: String?
    public var stdoutBase64: String?
    public var stderrBase64: String?
    public var chunks: [InitChannelStreamChunk]?
    public var meta: [String: String]?
    public var rawData: Data? = nil
    public var rawStdout: Data? = nil
    public var rawStderr: Data? = nil

    enum CodingKeys: String, CodingKey {
        case version
        case requestId
        case op
        case status
        case error
        case exitCode
        case stdout
        case stderr
        case durationMs
        case ptyId
        case procId
        case dataBase64
        case stdoutBase64
        case stderrBase64
        case chunks
        case meta
    }

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
        procId: String? = nil,
        dataBase64: String? = nil,
        stdoutBase64: String? = nil,
        stderrBase64: String? = nil,
        chunks: [InitChannelStreamChunk]? = nil,
        meta: [String: String]? = nil,
        rawData: Data? = nil,
        rawStdout: Data? = nil,
        rawStderr: Data? = nil
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
        self.procId = procId
        self.dataBase64 = dataBase64
        self.stdoutBase64 = stdoutBase64
        self.stderrBase64 = stderrBase64
        self.chunks = chunks
        self.meta = meta
        self.rawData = rawData
        self.rawStdout = rawStdout
        self.rawStderr = rawStderr
    }
}

public struct InitChannelStreamChunk: Codable {
    public var stream: String
    public var dataBase64: String
    public var rawData: Data? = nil

    enum CodingKeys: String, CodingKey {
        case stream
        case dataBase64
    }

    public init(stream: String, dataBase64: String) {
        self.stream = stream
        self.dataBase64 = dataBase64
    }
}

public enum InitChannelProcEventKind: String, Codable {
    case stdout
    case stderr
    case exited
    case streamsClosed = "streams_closed"
}

public struct InitChannelProcEvent {
    public var procId: String
    public var kind: InitChannelProcEventKind
    public var data: Data
    public var exitCode: Int32?
    public var text: String?
}

public enum InitChannelPtyEventKind: String, Codable {
    case output
    case exited
    case streamsClosed = "streams_closed"
}

public struct InitChannelPtyEvent {
    public var ptyId: String
    public var kind: InitChannelPtyEventKind
    public var data: Data
    public var exitCode: Int32?
    public var text: String?
}

private struct InitChannelEventHeader: Codable {
    var kind: String
    var ptyId: String?
    var procId: String?
    var exitCode: Int32?
    var text: String?
}

public final class InitChannelProcEventStream {
    private let fd: Int32
    private let retainedConnection: AnyObject?
    private let readFrame: (Int32, Int32, String) throws -> Data
    private let decodeFrame: (Data) throws -> (opcode: InitChannelFrameOpcode, header: Data, payload: Data)

    init(
        fd: Int32,
        retainedConnection: AnyObject?,
        readFrame: @escaping (Int32, Int32, String) throws -> Data,
        decodeFrame: @escaping (Data) throws -> (opcode: InitChannelFrameOpcode, header: Data, payload: Data)
    ) {
        self.fd = fd
        self.retainedConnection = retainedConnection
        self.readFrame = readFrame
        self.decodeFrame = decodeFrame
    }

    deinit {
        _ = close(fd)
    }

    var fileDescriptor: Int32 { fd }

    public func nextEvent() throws -> InitChannelProcEvent? {
        let frameData = try readFrame(fd, -1, "proc_subscribe")
        let frame = try decodeFrame(frameData)
        guard frame.opcode == .procEvent else {
            throw MSLRuntimeError("unexpected init channel proc event opcode \(frame.opcode.rawValue)")
        }
        let header = try JSONDecoder().decode(InitChannelEventHeader.self, from: frame.header)
        guard let procId = header.procId, let kind = InitChannelProcEventKind(rawValue: header.kind) else {
            throw MSLRuntimeError("invalid proc subscribe event header")
        }
        return InitChannelProcEvent(
            procId: procId,
            kind: kind,
            data: frame.payload,
            exitCode: header.exitCode,
            text: header.text
        )
    }
}

public final class InitChannelPtyEventStream {
    private let fd: Int32
    private let retainedConnection: AnyObject?
    private let readFrame: (Int32, Int32, String) throws -> Data
    private let decodeFrame: (Data) throws -> (opcode: InitChannelFrameOpcode, header: Data, payload: Data)

    init(
        fd: Int32,
        retainedConnection: AnyObject?,
        readFrame: @escaping (Int32, Int32, String) throws -> Data,
        decodeFrame: @escaping (Data) throws -> (opcode: InitChannelFrameOpcode, header: Data, payload: Data)
    ) {
        self.fd = fd
        self.retainedConnection = retainedConnection
        self.readFrame = readFrame
        self.decodeFrame = decodeFrame
    }

    deinit {
        _ = close(fd)
    }

    var fileDescriptor: Int32 { fd }

    public func nextEvent() throws -> InitChannelPtyEvent? {
        let frameData = try readFrame(fd, -1, "pty_subscribe")
        let frame = try decodeFrame(frameData)
        guard frame.opcode == .ptyEvent else {
            throw MSLRuntimeError("unexpected init channel pty event opcode \(frame.opcode.rawValue)")
        }
        let header = try JSONDecoder().decode(InitChannelEventHeader.self, from: frame.header)
        guard let ptyId = header.ptyId, let kind = InitChannelPtyEventKind(rawValue: header.kind) else {
            throw MSLRuntimeError("invalid pty subscribe event header")
        }
        return InitChannelPtyEvent(
            ptyId: ptyId,
            kind: kind,
            data: frame.payload,
            exitCode: header.exitCode,
            text: header.text
        )
    }
}

private struct InitChannelDirectHeader: Codable {
    var version: Int
    var requestId: String
    var op: String
    var status: String?
    var error: InitChannelErrorPayload?
    var exitCode: Int32?
    var durationMs: Int?
    var ptyId: String?
    var procId: String?
    var timeoutMs: Int?
    var meta: [String: String]?
    var chunks: [InitChannelDirectChunkDescriptor]?
}

private struct InitChannelDirectChunkDescriptor: Codable {
    var stream: String
    var length: Int
}

private enum InitChannelBinaryStreamKind: UInt8 {
    case stdout = 1
    case stderr = 2
}

private struct InitChannelBinaryPtyReadHeader {
    var ok: Bool
    var exitCode: Int32?
    var id: String
    var text: String?
}

private struct InitChannelBinaryProcReadHeader {
    var ok: Bool
    var exitCode: Int32?
    var procID: String
    var text: String?
    var descriptors: [(stream: String, length: Int)]
}

enum InitChannelFrameOpcode: UInt32 {
    case jsonRPCRequest = 1
    case jsonRPCResponse = 2
    case ptyReadRequest = 3
    case ptyReadResponse = 4
    case ptyWriteRequest = 5
    case ptyWriteResponse = 6
    case procReadRequest = 7
    case procReadResponse = 8
    case procWriteRequest = 9
    case procWriteResponse = 10
    case procSubscribeRequest = 11
    case procEvent = 12
    case ptySubscribeRequest = 13
    case ptyEvent = 14
}

private let initChannelFrameMagic: UInt32 = 0x4D534C49 // "MSLI"

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
    public typealias SidebandConnection = (fd: Int32, retainedConnection: AnyObject?)
    public typealias TraceLogger = (_ event: String, _ fields: [String: String]) -> Void

    private let socketPath: String
    private let handoffPath: String?
    private let ackPath: String?
    private let retryCount: Int
    private let retryDelayMs: Int
    private let timeoutMs: Int
    private let vsockFD: Int32?
    private let retainedVsockConnection: AnyObject?
    private let sidebandConnector: (() throws -> SidebandConnection)?
    private let sidebandSupported: Bool
    private let allowSocketFallback: Bool
    private let allowStreamingOnVsock: Bool
    private let traceLogger: TraceLogger?
    private let vsockLock = NSLock()
    private let persistentSidebandLock = NSLock()
    private var persistentSidebandFD: Int32 = -1
    private var persistentSidebandRetainedConnection: AnyObject?

    public var supportsDedicatedSideband: Bool {
        (sidebandSupported && sidebandConnector != nil) || (vsockFD == nil && allowSocketFallback)
    }

    public init(
        socketPath: String,
        handoffPath: String? = nil,
        ackPath: String? = nil,
        retryCount: Int = 10,
        retryDelayMs: Int = 100,
        timeoutMs: Int = 1_000,
        vsockFD: Int32? = nil,
        retainedVsockConnection: AnyObject? = nil,
        sidebandConnector: (() throws -> SidebandConnection)? = nil,
        sidebandSupported: Bool = false,
        allowSocketFallback: Bool = true,
        allowStreamingOnVsock: Bool = false,
        traceLogger: TraceLogger? = nil
    ) {
        self.socketPath = socketPath
        self.handoffPath = handoffPath
        self.ackPath = ackPath
        self.retryCount = retryCount
        self.retryDelayMs = retryDelayMs
        self.timeoutMs = timeoutMs
        self.vsockFD = vsockFD
        self.retainedVsockConnection = retainedVsockConnection
        self.sidebandConnector = sidebandConnector
        self.sidebandSupported = sidebandSupported
        self.allowSocketFallback = allowSocketFallback
        self.allowStreamingOnVsock = allowStreamingOnVsock
        self.traceLogger = traceLogger
    }

    deinit {
        persistentSidebandLock.lock()
        defer { persistentSidebandLock.unlock() }
        if persistentSidebandFD >= 0 {
            _ = close(persistentSidebandFD)
            persistentSidebandFD = -1
        }
        persistentSidebandRetainedConnection = nil
    }

    private func trace(_ event: String, _ fields: [String: String]) {
        traceLogger?(event, fields)
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
        envAdditions: [String: String]? = nil,
        runAsRoot: Bool? = nil,
        rows: Int?,
        cols: Int?,
        timeoutMs: Int? = nil
    ) throws -> InitChannelResponse {
        try send(InitChannelRequest(
            op: "pty_open",
            argv: argv,
            envAdditions: envAdditions,
            runAsRoot: runAsRoot,
            cwd: cwd,
            timeoutMs: timeoutMs ?? self.timeoutMs,
            rows: rows,
            cols: cols
        ))
    }

    public func ptyRead(ptyId: String, timeoutMs: Int? = nil) throws -> InitChannelResponse {
        let header = InitChannelDirectHeader(
            version: 1,
            requestId: UUID().uuidString,
            op: "pty_read",
            status: nil,
            error: nil,
            exitCode: nil,
            durationMs: nil,
            ptyId: ptyId,
            procId: nil,
            timeoutMs: timeoutMs ?? self.timeoutMs,
            meta: nil,
            chunks: nil
        )
        let frame = try sendDirect(opcode: .ptyReadRequest, header: header, payload: Data())
        return try decodeDirectPtyReadResponse(frame)
    }

    public func ptyWrite(ptyId: String, data: Data, timeoutMs: Int? = nil) throws -> InitChannelResponse {
        let header = InitChannelDirectHeader(
            version: 1,
            requestId: UUID().uuidString,
            op: "pty_write",
            status: nil,
            error: nil,
            exitCode: nil,
            durationMs: nil,
            ptyId: ptyId,
            procId: nil,
            timeoutMs: timeoutMs ?? self.timeoutMs,
            meta: nil,
            chunks: nil
        )
        let frame = try sendDirect(opcode: .ptyWriteRequest, header: header, payload: data)
        return try decodeDirectAckResponse(frame, expectedOp: "pty_write")
    }

    public func ptyOpen(
        argv: [String],
        cwd: String? = nil,
        envAdditions: [String: String]? = nil,
        runAsRoot: Bool? = nil,
        rows: Int,
        cols: Int,
        timeoutMs: Int? = nil
    ) throws -> InitChannelResponse {
        try send(InitChannelRequest(
            op: "pty_open",
            argv: argv,
            envAdditions: envAdditions,
            runAsRoot: runAsRoot,
            cwd: cwd,
            timeoutMs: timeoutMs ?? self.timeoutMs,
            rows: rows,
            cols: cols
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

    public func procOpen(
        argv: [String],
        cwd: String? = nil,
        envAdditions: [String: String]? = nil,
        runAsRoot: Bool? = nil,
        timeoutMs: Int? = nil
    ) throws -> InitChannelResponse {
        try send(InitChannelRequest(
            op: "proc_open",
            argv: argv,
            envAdditions: envAdditions,
            runAsRoot: runAsRoot,
            cwd: cwd,
            timeoutMs: timeoutMs ?? self.timeoutMs
        ))
    }

    public func procRead(procId: String, timeoutMs: Int? = nil) throws -> InitChannelResponse {
        let header = InitChannelDirectHeader(
            version: 1,
            requestId: UUID().uuidString,
            op: "proc_read",
            status: nil,
            error: nil,
            exitCode: nil,
            durationMs: nil,
            ptyId: nil,
            procId: procId,
            timeoutMs: timeoutMs ?? self.timeoutMs,
            meta: nil,
            chunks: nil
        )
        let frame = try sendDirect(opcode: .procReadRequest, header: header, payload: Data())
        return try decodeDirectProcReadResponse(frame)
    }

    public func procWrite(procId: String, data: Data, timeoutMs: Int? = nil) throws -> InitChannelResponse {
        try send(InitChannelRequest(
            op: "proc_write",
            timeoutMs: timeoutMs ?? self.timeoutMs,
            procId: procId,
            dataBase64: data.base64EncodedString()
        ))
    }

    public func procStdinClose(procId: String, timeoutMs: Int? = nil) throws -> InitChannelResponse {
        try send(InitChannelRequest(
            op: "proc_stdin_close",
            timeoutMs: timeoutMs ?? self.timeoutMs,
            procId: procId
        ))
    }

    public func procSubscribe(procId: String) throws -> InitChannelProcEventStream {
        let header = InitChannelDirectHeader(
            version: 1,
            requestId: UUID().uuidString,
            op: "proc_subscribe",
            status: nil,
            error: nil,
            exitCode: nil,
            durationMs: nil,
            ptyId: nil,
            procId: procId,
            timeoutMs: nil,
            meta: nil,
            chunks: nil
        )
        let streamConnection = try openDirectStream(opcode: .procSubscribeRequest, header: header, payload: Data())
        return InitChannelProcEventStream(
            fd: streamConnection.fd,
            retainedConnection: streamConnection.retainedConnection,
            readFrame: { try self.readFrame(from: $0, readTimeoutMs: $1, op: $2) },
            decodeFrame: { try self.decodeFrame($0) }
        )
    }

    public func ptySubscribe(ptyId: String) throws -> InitChannelPtyEventStream {
        let header = InitChannelDirectHeader(
            version: 1,
            requestId: UUID().uuidString,
            op: "pty_subscribe",
            status: nil,
            error: nil,
            exitCode: nil,
            durationMs: nil,
            ptyId: ptyId,
            procId: nil,
            timeoutMs: nil,
            meta: nil,
            chunks: nil
        )
        let streamConnection = try openDirectStream(opcode: .ptySubscribeRequest, header: header, payload: Data())
        return InitChannelPtyEventStream(
            fd: streamConnection.fd,
            retainedConnection: streamConnection.retainedConnection,
            readFrame: { try self.readFrame(from: $0, readTimeoutMs: $1, op: $2) },
            decodeFrame: { try self.decodeFrame($0) }
        )
    }

    public func makeSidebandClient() -> InitChannelClient {
        let parent = self
        return InitChannelClient(
            socketPath: socketPath,
            handoffPath: nil,
            ackPath: nil,
            retryCount: retryCount,
            retryDelayMs: retryDelayMs,
            timeoutMs: timeoutMs,
            vsockFD: nil,
            retainedVsockConnection: nil,
            sidebandConnector: {
                try parent.requestSidebandConnection(role: "sideband")
                guard let connector = parent.sidebandConnector else {
                    throw MSLRuntimeError("sideband acquire failed: no broker-backed init channel available")
                }
                return try connector()
            },
            sidebandSupported: parent.sidebandConnector != nil,
            allowSocketFallback: false,
            allowStreamingOnVsock: true,
            traceLogger: parent.traceLogger
        )
    }

    private func requestSidebandConnection(role: String) throws {
        guard sidebandConnector != nil else {
            throw MSLRuntimeError("sideband acquire failed: no broker-backed init channel available")
        }
        trace("init_transport_sideband_open_started", [
            "role": role
        ])
        let response = try send(InitChannelRequest(
            op: "sideband_open",
            timeoutMs: timeoutMs,
            sidebandRole: role
        ))
        guard response.ok else {
            trace("init_transport_sideband_open_failed", [
                "role": role,
                "error": response.error?.message ?? "sideband_open failed"
            ])
            throw MSLRuntimeError(response.error?.message ?? "sideband_open failed")
        }
        trace("init_transport_sideband_open_succeeded", [
            "role": role
        ])
    }

    public func procClose(procId: String, timeoutMs: Int? = nil) throws -> InitChannelResponse {
        try send(InitChannelRequest(
            op: "proc_close",
            timeoutMs: timeoutMs ?? self.timeoutMs,
            procId: procId
        ))
    }

    public func waylandProxyStart(
        displayName: String,
        displayPort: Int,
        runtimeDir: String = "/tmp",
        timeoutMs: Int? = nil
    ) throws -> InitChannelResponse {
        try send(InitChannelRequest(
            op: "wayland_proxy_start",
            timeoutMs: timeoutMs ?? self.timeoutMs,
            displayName: displayName,
            displayPort: displayPort,
            runtimeDir: runtimeDir
        ))
    }

    public func waylandProxyStop(
        displayName: String,
        timeoutMs: Int? = nil
    ) throws -> InitChannelResponse {
        try send(InitChannelRequest(
            op: "wayland_proxy_stop",
            timeoutMs: timeoutMs ?? self.timeoutMs,
            displayName: displayName
        ))
    }

    public func waylandProxyStatus(
        displayName: String? = nil,
        timeoutMs: Int? = nil
    ) throws -> InitChannelResponse {
        try send(InitChannelRequest(
            op: "wayland_proxy_status",
            timeoutMs: timeoutMs ?? self.timeoutMs,
            displayName: displayName
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
        if let sidebandConnector {
            _ = sidebandConnector
            return try sendViaPersistentSideband(request, effectiveTimeoutMs: effectiveTimeoutMs)
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

    private func sendViaDedicatedVsock(
        _ request: InitChannelRequest,
        connection: SidebandConnection,
        effectiveTimeoutMs: Int
    ) throws -> InitChannelResponse {
        defer {
            _ = connection.retainedConnection
            _ = close(connection.fd)
        }
        let frame = try makeJSONRPCRequestFrame(request)
        trace("init_transport_write_started", [
            "op": request.op,
            "transport": "sideband_vsock",
            "fd": String(connection.fd)
        ])
        do {
            try writeFrame(frame, to: connection.fd, writeTimeoutMs: max(effectiveTimeoutMs, 10_000))
        } catch {
            trace("init_transport_write_failed", [
                "op": request.op,
                "transport": "sideband_vsock",
                "fd": String(connection.fd),
                "error": String(describing: error)
            ])
            throw error
        }
        let readTimeoutMs: Int32 = effectiveTimeoutMs <= 0 ? -1 : Int32(max(effectiveTimeoutMs, 30_000))
        do {
            let responseFrame = try readFrame(from: connection.fd, readTimeoutMs: readTimeoutMs, op: request.op)
            do {
                return try decodeJSONRPCResponseFrame(responseFrame)
            } catch {
                trace("init_transport_response_decode_failed", [
                    "op": request.op,
                    "transport": "sideband_vsock",
                    "fd": String(connection.fd),
                    "error": String(describing: error)
                ])
                throw error
            }
        } catch {
            trace("init_transport_response_failed", [
                "op": request.op,
                "transport": "sideband_vsock",
                "fd": String(connection.fd),
                "error": String(describing: error)
            ])
            throw error
        }
    }

    private func sendViaPersistentSideband(
        _ request: InitChannelRequest,
        effectiveTimeoutMs: Int
    ) throws -> InitChannelResponse {
        try withPersistentSidebandConnection { connection in
            let frame = try makeJSONRPCRequestFrame(request)
            trace("init_transport_write_started", [
                "op": request.op,
                "transport": "persistent_sideband_vsock",
                "fd": String(connection.fd)
            ])
            do {
                try writeFrame(frame, to: connection.fd, writeTimeoutMs: max(effectiveTimeoutMs, 10_000))
            } catch {
                trace("init_transport_write_failed", [
                    "op": request.op,
                    "transport": "persistent_sideband_vsock",
                    "fd": String(connection.fd),
                    "error": String(describing: error)
                ])
                throw error
            }
            let readTimeoutMs: Int32 = effectiveTimeoutMs <= 0 ? -1 : Int32(max(effectiveTimeoutMs, 30_000))
            do {
                let responseFrame = try readFrame(from: connection.fd, readTimeoutMs: readTimeoutMs, op: request.op)
                do {
                    return try decodeJSONRPCResponseFrame(responseFrame)
                } catch {
                    trace("init_transport_response_decode_failed", [
                        "op": request.op,
                        "transport": "persistent_sideband_vsock",
                        "fd": String(connection.fd),
                        "error": String(describing: error)
                    ])
                    throw error
                }
            } catch {
                trace("init_transport_response_failed", [
                    "op": request.op,
                    "transport": "persistent_sideband_vsock",
                    "fd": String(connection.fd),
                    "error": String(describing: error)
                ])
                throw error
            }
        }
    }

    private func withPersistentSidebandConnection<T>(
        _ body: (SidebandConnection) throws -> T
    ) throws -> T {
        persistentSidebandLock.lock()
        defer { persistentSidebandLock.unlock() }
        if persistentSidebandFD < 0 {
            guard let sidebandConnector else {
                throw MSLRuntimeError("sideband acquire failed: no broker-backed init channel available")
            }
            let connection = try sidebandConnector()
            persistentSidebandFD = connection.fd
            persistentSidebandRetainedConnection = connection.retainedConnection
        }
        do {
            return try body((persistentSidebandFD, persistentSidebandRetainedConnection))
        } catch {
            if persistentSidebandFD >= 0 {
                _ = close(persistentSidebandFD)
                persistentSidebandFD = -1
            }
            persistentSidebandRetainedConnection = nil
            throw error
        }
    }

    private func sendViaPersistentVsock(
        _ request: InitChannelRequest,
        fd: Int32,
        effectiveTimeoutMs: Int
    ) throws -> InitChannelResponse {
        vsockLock.lock()
        defer { vsockLock.unlock() }

        let frame = try makeJSONRPCRequestFrame(request)

        // Write with poll() to detect write stalls
        trace("init_transport_write_started", [
            "op": request.op,
            "transport": "persistent_vsock",
            "fd": String(fd)
        ])
        do {
            try writeFrame(frame, to: fd, writeTimeoutMs: 10_000)
        } catch {
            trace("init_transport_write_failed", [
                "op": request.op,
                "transport": "persistent_vsock",
                "fd": String(fd),
                "error": String(describing: error)
            ])
            throw error
        }

        // Read with poll() timeout since setsockopt(SO_RCVTIMEO) doesn't work on VZ fds.
        // Use 30s timeout to tolerate temporary vsock latency spikes during early boot.
        let readTimeoutMs: Int32
        if effectiveTimeoutMs <= 0 {
            readTimeoutMs = -1
        } else {
            readTimeoutMs = Int32(max(effectiveTimeoutMs, 30_000))
        }
        do {
            let responseFrame = try readFrame(from: fd, readTimeoutMs: readTimeoutMs, op: request.op)
            do {
                return try decodeJSONRPCResponseFrame(responseFrame)
            } catch {
                trace("init_transport_response_decode_failed", [
                    "op": request.op,
                    "transport": "persistent_vsock",
                    "fd": String(fd),
                    "error": String(describing: error)
                ])
                throw error
            }
        } catch {
            trace("init_transport_response_failed", [
                "op": request.op,
                "transport": "persistent_vsock",
                "fd": String(fd),
                "error": String(describing: error)
            ])
            throw error
        }
    }

    private func sendViaSocket(_ request: InitChannelRequest, effectiveTimeoutMs: Int) throws -> InitChannelResponse {
        let fd = try connectWithRetry()
        defer { close(fd) }
        try configureTimeout(fd, effectiveTimeoutMs: effectiveTimeoutMs)

        let frame = try makeJSONRPCRequestFrame(request)
        try writeFrame(frame, to: fd, writeTimeoutMs: max(effectiveTimeoutMs, 10_000))

        let readTimeoutMs: Int32 = effectiveTimeoutMs <= 0 ? -1 : Int32(effectiveTimeoutMs)
        let responseFrame = try readFrame(from: fd, readTimeoutMs: readTimeoutMs, op: request.op)
        return try decodeJSONRPCResponseFrame(responseFrame)
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

        let frame = try makeJSONRPCRequestFrame(request)
        try frame.write(to: handoffURL, options: .atomic)

        let deadline: Int64 = effectiveTimeoutMs > 0 ? nowEpochMs() + Int64(effectiveTimeoutMs) : Int64.max
        var lastAckRequestID: String?
        var ackDecodeError: String?
        while nowEpochMs() <= deadline {
            if fm.fileExists(atPath: ackURL.path) {
                do {
                    let data = try Data(contentsOf: ackURL)
                    let response = try decodeJSONRPCResponseFrame(data)
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

    func makeJSONRPCRequestFrame(_ request: InitChannelRequest) throws -> Data {
        try encodeFrame(opcode: .jsonRPCRequest, header: Data(), payload: encode(request))
    }

    func decodeJSONRPCResponseFrame(_ data: Data) throws -> InitChannelResponse {
        let frame = try decodeFrame(data)
        guard frame.opcode == .jsonRPCResponse else {
            throw MSLRuntimeError("unexpected init channel frame opcode \(frame.opcode.rawValue)")
        }
        guard frame.header.isEmpty else {
            throw MSLRuntimeError("unexpected init channel frame header payload")
        }
        return try decode(frame.payload)
    }

    private func sendDirect(opcode: InitChannelFrameOpcode, header: InitChannelDirectHeader, payload: Data) throws -> Data {
        let effectiveTimeoutMs = header.timeoutMs ?? timeoutMs
        let encodedHeader = try JSONEncoder().encode(header)
        let frame = try encodeFrame(opcode: opcode, header: encodedHeader, payload: payload)
        if let sidebandConnector {
            _ = sidebandConnector
            if vsockFD != nil && persistentSidebandFD < 0 {
                try requestSidebandConnection(role: "sideband")
            }
            return try withPersistentSidebandConnection { connection in
                trace("init_transport_direct_write_started", [
                    "op": header.op,
                    "transport": "persistent_sideband_vsock",
                    "fd": String(connection.fd),
                    "opcode": String(opcode.rawValue)
                ])
                do {
                    try writeFrame(frame, to: connection.fd, writeTimeoutMs: 10_000)
                } catch {
                    trace("init_transport_direct_write_failed", [
                        "op": header.op,
                        "transport": "persistent_sideband_vsock",
                        "fd": String(connection.fd),
                        "opcode": String(opcode.rawValue),
                        "error": String(describing: error)
                    ])
                    throw error
                }
                let readTimeoutMs: Int32 = effectiveTimeoutMs <= 0 ? -1 : Int32(max(effectiveTimeoutMs, 30_000))
                do {
                    let response = try readFrame(from: connection.fd, readTimeoutMs: readTimeoutMs, op: header.op)
                    trace("init_transport_direct_read_succeeded", [
                        "op": header.op,
                        "transport": "persistent_sideband_vsock",
                        "fd": String(connection.fd),
                        "opcode": String(opcode.rawValue)
                    ])
                    return response
                } catch {
                    trace("init_transport_direct_read_failed", [
                        "op": header.op,
                        "transport": "persistent_sideband_vsock",
                        "fd": String(connection.fd),
                        "opcode": String(opcode.rawValue),
                        "error": String(describing: error)
                    ])
                    throw error
                }
            }
        }
        if let fd = vsockFD {
            vsockLock.lock()
            defer { vsockLock.unlock() }
            trace("init_transport_direct_write_started", [
                "op": header.op,
                "transport": "persistent_vsock",
                "fd": String(fd),
                "opcode": String(opcode.rawValue)
            ])
            do {
                try writeFrame(frame, to: fd, writeTimeoutMs: 10_000)
            } catch {
                trace("init_transport_direct_write_failed", [
                    "op": header.op,
                    "transport": "persistent_vsock",
                    "fd": String(fd),
                    "opcode": String(opcode.rawValue),
                    "error": String(describing: error)
                ])
                throw error
            }
            let readTimeoutMs: Int32 = effectiveTimeoutMs <= 0 ? -1 : Int32(max(effectiveTimeoutMs, 30_000))
            do {
                let response = try readFrame(from: fd, readTimeoutMs: readTimeoutMs, op: header.op)
                trace("init_transport_direct_read_succeeded", [
                    "op": header.op,
                    "transport": "persistent_vsock",
                    "fd": String(fd),
                    "opcode": String(opcode.rawValue)
                ])
                return response
            } catch {
                trace("init_transport_direct_read_failed", [
                    "op": header.op,
                    "transport": "persistent_vsock",
                    "fd": String(fd),
                    "opcode": String(opcode.rawValue),
                    "error": String(describing: error)
                ])
                throw error
            }
        }
        if let handoffPath, let ackPath {
            let fm = FileManager.default
            let handoffURL = URL(fileURLWithPath: handoffPath)
            let ackURL = URL(fileURLWithPath: ackPath)
            try fm.createDirectory(at: handoffURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try frame.write(to: handoffURL, options: .atomic)
            let deadline: Int64 = effectiveTimeoutMs > 0 ? nowEpochMs() + Int64(effectiveTimeoutMs) : Int64.max
            while nowEpochMs() <= deadline {
                if fm.fileExists(atPath: ackURL.path) {
                    return try Data(contentsOf: ackURL)
                }
                usleep(50_000)
            }
            throw MSLRuntimeError("init channel timeout via file handoff")
        }
        let fd = try connectWithRetry()
        defer { close(fd) }
        try configureTimeout(fd, effectiveTimeoutMs: effectiveTimeoutMs)
        try writeFrame(frame, to: fd, writeTimeoutMs: max(effectiveTimeoutMs, 10_000))
        let readTimeoutMs: Int32 = effectiveTimeoutMs <= 0 ? -1 : Int32(effectiveTimeoutMs)
        return try readFrame(from: fd, readTimeoutMs: readTimeoutMs, op: header.op)
    }

    private func openDirectStream(opcode: InitChannelFrameOpcode, header: InitChannelDirectHeader, payload: Data) throws -> (fd: Int32, retainedConnection: AnyObject?) {
        let encodedHeader = try JSONEncoder().encode(header)
        let frame = try encodeFrame(opcode: opcode, header: encodedHeader, payload: payload)
        let connection: SidebandConnection
        if let sidebandConnector {
            if vsockFD != nil {
                try requestSidebandConnection(role: "sideband")
            }
            connection = try sidebandConnector()
        } else if let fd = vsockFD {
            if !allowStreamingOnVsock {
                throw MSLRuntimeError("direct subscribe requires socket-backed init channel client")
            }
            connection = (fd, retainedVsockConnection)
        } else {
            if !allowSocketFallback {
                throw MSLRuntimeError("sideband acquire failed: no broker-backed init channel available")
            }
            connection = (try connectWithRetry(), nil)
        }
        do {
            try configureTimeout(connection.fd, effectiveTimeoutMs: 0)
            trace("init_transport_stream_open_started", [
                "op": header.op,
                "transport": connection.fd == vsockFD ? "persistent_vsock" : "sideband_vsock",
                "fd": String(connection.fd)
            ])
            try writeFrame(frame, to: connection.fd, writeTimeoutMs: max(timeoutMs, 10_000))
            trace("init_transport_stream_open_succeeded", [
                "op": header.op,
                "transport": connection.fd == vsockFD ? "persistent_vsock" : "sideband_vsock",
                "fd": String(connection.fd)
            ])
            return connection
        } catch {
            trace("init_transport_stream_open_failed", [
                "op": header.op,
                "transport": connection.fd == vsockFD ? "persistent_vsock" : "sideband_vsock",
                "fd": String(connection.fd),
                "error": String(describing: error)
            ])
            if connection.fd != vsockFD {
                close(connection.fd)
            }
            throw error
        }
    }

    private func decodeDirectAckResponse(_ frameData: Data, expectedOp: String) throws -> InitChannelResponse {
        let frame = try decodeFrame(frameData)
        let header = try JSONDecoder().decode(InitChannelDirectHeader.self, from: frame.header)
        return InitChannelResponse(
            requestId: header.requestId,
            op: header.op.isEmpty ? expectedOp : header.op,
            status: header.status ?? "ok",
            error: header.error,
            exitCode: header.exitCode,
            durationMs: header.durationMs,
            ptyId: header.ptyId,
            procId: header.procId,
            meta: header.meta
        )
    }

    private func decodeDirectPtyReadResponse(_ frameData: Data) throws -> InitChannelResponse {
        let frame = try decodeFrame(frameData)
        let header = try decodeBinaryPtyReadHeader(frame.header)
        return InitChannelResponse(
            requestId: "",
            op: "pty_read",
            status: header.ok ? "ok" : "error",
            error: header.ok ? nil : InitChannelErrorPayload(code: .internalError, message: header.text ?? "pty_read failed"),
            exitCode: header.exitCode,
            ptyId: header.id,
            dataBase64: frame.payload.isEmpty ? nil : frame.payload.base64EncodedString(),
            meta: header.exitCode == nil ? nil : ["exitCode": String(header.exitCode!)],
            rawData: frame.payload
        )
    }

    private func decodeDirectProcReadResponse(_ frameData: Data) throws -> InitChannelResponse {
        let frame = try decodeFrame(frameData)
        let header = try decodeBinaryProcReadHeader(frame.header)
        var stdout = Data()
        var stderr = Data()
        var chunks: [InitChannelStreamChunk] = []
        var offset = 0
        for descriptor in header.descriptors {
            guard descriptor.length >= 0, offset + descriptor.length <= frame.payload.count else {
                throw MSLRuntimeError("invalid direct proc_read chunk layout")
            }
            let chunk = frame.payload.subdata(in: offset..<(offset + descriptor.length))
            offset += descriptor.length
            switch descriptor.stream {
            case "stdout":
                stdout.append(chunk)
            case "stderr":
                stderr.append(chunk)
            default:
                break
            }
            var chunkEntry = InitChannelStreamChunk(stream: descriptor.stream, dataBase64: chunk.base64EncodedString())
            chunkEntry.rawData = chunk
            chunks.append(chunkEntry)
        }
        var meta: [String: String]? = nil
        if let exitCode = header.exitCode {
            meta = ["exitCode": String(exitCode)]
            if let text = header.text, !text.isEmpty {
                meta?["exitReason"] = text
            }
        }
        return InitChannelResponse(
            requestId: "",
            op: "proc_read",
            status: header.ok ? "ok" : "error",
            error: header.ok ? nil : InitChannelErrorPayload(code: .internalError, message: header.text ?? "proc_read failed"),
            exitCode: header.exitCode,
            procId: header.procID,
            stdoutBase64: stdout.isEmpty ? nil : stdout.base64EncodedString(),
            stderrBase64: stderr.isEmpty ? nil : stderr.base64EncodedString(),
            chunks: chunks.isEmpty ? nil : chunks,
            meta: meta,
            rawStdout: stdout.isEmpty ? nil : stdout,
            rawStderr: stderr.isEmpty ? nil : stderr
        )
    }

    func encodeFrame(opcode: InitChannelFrameOpcode, header: Data, payload: Data) throws -> Data {
        var data = Data()
        data.append(u32be(initChannelFrameMagic))
        data.append(u32be(opcode.rawValue))
        data.append(u32be(UInt32(header.count)))
        data.append(u32be(UInt32(payload.count)))
        data.append(header)
        data.append(payload)
        return data
    }

    func decodeFrame(_ data: Data) throws -> (opcode: InitChannelFrameOpcode, header: Data, payload: Data) {
        guard data.count >= 16 else {
            throw MSLRuntimeError("short init channel frame")
        }
        let magic = readU32BE(data, offset: 0)
        guard magic == initChannelFrameMagic else {
            throw MSLRuntimeError("invalid init channel frame magic")
        }
        let opcodeValue = readU32BE(data, offset: 4)
        guard let opcode = InitChannelFrameOpcode(rawValue: opcodeValue) else {
            throw MSLRuntimeError("unsupported init channel frame opcode \(opcodeValue)")
        }
        let headerLength = Int(readU32BE(data, offset: 8))
        let payloadLength = Int(readU32BE(data, offset: 12))
        let expectedLength = 16 + headerLength + payloadLength
        guard data.count == expectedLength else {
            throw MSLRuntimeError("invalid init channel frame length")
        }
        let headerStart = 16
        let payloadStart = headerStart + headerLength
        return (
            opcode,
            data.subdata(in: headerStart..<payloadStart),
            data.subdata(in: payloadStart..<expectedLength)
        )
    }

    func readFrameForTest(from fd: Int32, op: String) throws -> Data {
        try readFrame(from: fd, readTimeoutMs: 1_000, op: op)
    }

    private func writeFrame(_ frame: Data, to fd: Int32, writeTimeoutMs: Int) throws {
        try frame.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var remaining = raw.count
            var offset = 0
            while remaining > 0 {
                var wpfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let wready = poll(&wpfd, 1, Int32(writeTimeoutMs))
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
    }

    private func readFrame(from fd: Int32, readTimeoutMs: Int32, op: String) throws -> Data {
        let header = try readExact(from: fd, byteCount: 16, readTimeoutMs: readTimeoutMs, op: op)
        let headerLength = Int(readU32BE(header, offset: 8))
        let payloadLength = Int(readU32BE(header, offset: 12))
        let remainder = try readExact(
            from: fd,
            byteCount: headerLength + payloadLength,
            readTimeoutMs: readTimeoutMs,
            op: op
        )
        var frame = Data()
        frame.append(header)
        frame.append(remainder)
        return frame
    }

    private func readExact(from fd: Int32, byteCount: Int, readTimeoutMs: Int32, op: String) throws -> Data {
        var buffer = Data(count: byteCount)
        var offset = 0
        try buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < byteCount {
                var rpfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let rready = poll(&rpfd, 1, readTimeoutMs)
                if rready == 0 {
                    throw MSLRuntimeError("vsock read timeout (\(readTimeoutMs)ms) for op=\(op)")
                }
                if rready < 0 {
                    if errno == EINTR { continue }
                    throw MSLRuntimeError("vsock read poll failed: \(lastErr())")
                }
                let revents = rpfd.revents
                if (revents & Int16(POLLHUP)) != 0 && (revents & Int16(POLLIN)) == 0 {
                    throw MSLRuntimeError("vsock connection lost (revents=\(revents)) for op=\(op)")
                }
                if (revents & Int16(POLLERR)) != 0 {
                    throw MSLRuntimeError("vsock connection lost (revents=\(revents)) for op=\(op)")
                }
                let n = read(fd, base + offset, byteCount - offset)
                if n == 0 {
                    throw MSLRuntimeError("vsock connection closed by guest")
                }
                if n < 0 {
                    throw MSLRuntimeError("vsock read failed: \(lastErr())")
                }
                offset += n
            }
        }
        return buffer
    }
}

private func lastErr() -> String {
    String(cString: strerror(errno))
}

private func u32be(_ value: UInt32) -> Data {
    var bigEndian = value.bigEndian
    return withUnsafeBytes(of: &bigEndian) { Data($0) }
}

private func i32be(_ value: Int32) -> Data {
    var bigEndian = value.bigEndian
    return withUnsafeBytes(of: &bigEndian) { Data($0) }
}

private func readU32BE(_ data: Data, offset: Int) -> UInt32 {
    let slice = data[offset..<(offset + 4)]
    return slice.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
}

private func readI32BE(_ data: Data, offset: Int) -> Int32 {
    let value = readU32BE(data, offset: offset)
    return Int32(bitPattern: value)
}

private func readBinaryUTF8(_ data: Data, offset: inout Int, length: Int) throws -> String {
    guard length >= 0, offset + length <= data.count else {
        throw MSLRuntimeError("invalid binary header string length")
    }
    let slice = data.subdata(in: offset..<(offset + length))
    offset += length
    guard let string = String(data: slice, encoding: .utf8) else {
        throw MSLRuntimeError("invalid utf8 in binary header")
    }
    return string
}

private func encodeBinaryPtyReadHeader(ok: Bool, exitCode: Int32?, id: String, text: String?) -> Data {
    let idData = Data(id.utf8)
    let textData = Data((text ?? "").utf8)
    var flags: UInt8 = 0
    if exitCode != nil { flags |= 1 << 0 }
    if !textData.isEmpty { flags |= 1 << 1 }
    var data = Data()
    data.append(ok ? 1 : 0)
    data.append(flags)
    data.append(contentsOf: [0, 0])
    data.append(i32be(exitCode ?? 0))
    data.append(u32be(UInt32(idData.count)))
    data.append(u32be(UInt32(textData.count)))
    data.append(idData)
    data.append(textData)
    return data
}

private func decodeBinaryPtyReadHeader(_ data: Data) throws -> InitChannelBinaryPtyReadHeader {
    guard data.count >= 16 else {
        throw MSLRuntimeError("short pty_read binary header")
    }
    let ok = data[0] == 1
    let flags = data[1]
    let exitCode = (flags & (1 << 0)) != 0 ? readI32BE(data, offset: 4) : nil
    let idLength = Int(readU32BE(data, offset: 8))
    let textLength = Int(readU32BE(data, offset: 12))
    var offset = 16
    let id = try readBinaryUTF8(data, offset: &offset, length: idLength)
    let text = textLength > 0 ? try readBinaryUTF8(data, offset: &offset, length: textLength) : nil
    return InitChannelBinaryPtyReadHeader(ok: ok, exitCode: exitCode, id: id, text: text)
}

private func encodeBinaryProcReadHeader(
    ok: Bool,
    exitCode: Int32?,
    procID: String,
    text: String?,
    descriptors: [(stream: String, length: Int)]
) -> Data {
    let idData = Data(procID.utf8)
    let textData = Data((text ?? "").utf8)
    var flags: UInt8 = 0
    if exitCode != nil { flags |= 1 << 0 }
    if !textData.isEmpty { flags |= 1 << 1 }
    var data = Data()
    data.append(ok ? 1 : 0)
    data.append(flags)
    data.append(contentsOf: [0, 0])
    data.append(i32be(exitCode ?? 0))
    data.append(u32be(UInt32(idData.count)))
    data.append(u32be(UInt32(textData.count)))
    data.append(u32be(UInt32(descriptors.count)))
    data.append(idData)
    data.append(textData)
    for descriptor in descriptors {
        let streamID: UInt8
        switch descriptor.stream {
        case "stdout":
            streamID = InitChannelBinaryStreamKind.stdout.rawValue
        case "stderr":
            streamID = InitChannelBinaryStreamKind.stderr.rawValue
        default:
            streamID = 0
        }
        data.append(streamID)
        data.append(contentsOf: [0, 0, 0])
        data.append(u32be(UInt32(descriptor.length)))
    }
    return data
}

private func decodeBinaryProcReadHeader(_ data: Data) throws -> InitChannelBinaryProcReadHeader {
    guard data.count >= 20 else {
        throw MSLRuntimeError("short proc_read binary header")
    }
    let ok = data[0] == 1
    let flags = data[1]
    let exitCode = (flags & (1 << 0)) != 0 ? readI32BE(data, offset: 4) : nil
    let idLength = Int(readU32BE(data, offset: 8))
    let textLength = Int(readU32BE(data, offset: 12))
    let chunkCount = Int(readU32BE(data, offset: 16))
    var offset = 20
    let procID = try readBinaryUTF8(data, offset: &offset, length: idLength)
    let text = textLength > 0 ? try readBinaryUTF8(data, offset: &offset, length: textLength) : nil
    var descriptors: [(stream: String, length: Int)] = []
    for _ in 0..<chunkCount {
        guard offset + 8 <= data.count else {
            throw MSLRuntimeError("short proc_read descriptor header")
        }
        let streamID = data[offset]
        offset += 4
        let length = Int(readU32BE(data, offset: offset))
        offset += 4
        let stream: String
        switch streamID {
        case InitChannelBinaryStreamKind.stdout.rawValue:
            stream = "stdout"
        case InitChannelBinaryStreamKind.stderr.rawValue:
            stream = "stderr"
        default:
            stream = "unknown"
        }
        descriptors.append((stream, length))
    }
    return InitChannelBinaryProcReadHeader(ok: ok, exitCode: exitCode, procID: procID, text: text, descriptors: descriptors)
}
