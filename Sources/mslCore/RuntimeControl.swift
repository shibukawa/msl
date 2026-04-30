import Foundation
import Darwin

private let runtimeControlMaxLineBytes = 4 * 1024 * 1024
private let runtimeControlFrameMagic: UInt32 = 0x4D534C52 // "MSLR"

private func runtimeControlConfigureNoSigPipe(fd: Int32) throws {
    var enabled: Int32 = 1
    if setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) != 0 {
        throw MSLRuntimeError("failed to configure control socket SO_NOSIGPIPE: \(String(cString: strerror(errno)))")
    }
}

private struct RuntimeControlDirectHeader: Codable {
    var op: String
    var status: String?
    var error: String?
    var exitCode: Int32?
    var ptyId: String?
    var procId: String?
    var timeoutMs: Int?
    var meta: [String: String]?
    var chunks: [RuntimeControlDirectChunkDescriptor]?
}

private struct RuntimeControlDirectChunkDescriptor: Codable {
    var stream: String
    var length: Int
}

enum RuntimeControlFrameOpcode: UInt32 {
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
    case procWriteAsyncRequest = 11
    case procSubscribeRequest = 12
    case procEvent = 13
    case ptySubscribeRequest = 14
    case ptyEvent = 15
}

func runtimeControlWriteAll(fd: Int32, data: Data) throws {
    try data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        var offset = 0
        while offset < raw.count {
            let written = write(fd, base.advanced(by: offset), raw.count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                throw MSLRuntimeError("runtime control write failed: \(String(cString: strerror(errno)))")
            }
            offset += written
        }
    }
}

private func runtimeControlU32BE(_ value: UInt32) -> Data {
    var be = value.bigEndian
    return withUnsafeBytes(of: &be) { Data($0) }
}

private func runtimeControlI32BE(_ value: Int32) -> Data {
    var be = value.bigEndian
    return withUnsafeBytes(of: &be) { Data($0) }
}

private func runtimeControlReadU32BE(_ data: Data, offset: Int) -> UInt32 {
    precondition(offset >= 0 && offset + 4 <= data.count)
    return (UInt32(data[offset]) << 24)
        | (UInt32(data[offset + 1]) << 16)
        | (UInt32(data[offset + 2]) << 8)
        | UInt32(data[offset + 3])
}

private func runtimeControlReadI32BE(_ data: Data, offset: Int) -> Int32 {
    Int32(bitPattern: runtimeControlReadU32BE(data, offset: offset))
}

private func runtimeControlReadBinaryUTF8(_ data: Data, offset: inout Int, length: Int) throws -> String {
    guard length >= 0, offset + length <= data.count else {
        throw MSLRuntimeError("invalid runtime control binary string length")
    }
    let chunk = data.subdata(in: offset..<(offset + length))
    offset += length
    guard let string = String(data: chunk, encoding: .utf8) else {
        throw MSLRuntimeError("invalid runtime control binary utf8")
    }
    return string
}

private enum RuntimeControlBinaryStreamKind: UInt8 {
    case stdout = 1
    case stderr = 2
}

private struct RuntimeControlBinaryPtyReadHeader {
    var ok: Bool
    var exitCode: Int32?
    var id: String
    var text: String?
}

private struct RuntimeControlBinaryProcReadHeader {
    var ok: Bool
    var exitCode: Int32?
    var procID: String
    var text: String?
    var descriptors: [(stream: String, length: Int)]
}

private func runtimeControlEncodeBinaryPtyReadHeader(
    ok: Bool,
    exitCode: Int32?,
    id: String,
    text: String?
) throws -> Data {
    let idBytes = Data(id.utf8)
    let textBytes = Data((text ?? "").utf8)
    var flags: UInt8 = 0
    if exitCode != nil {
        flags |= 1 << 0
    }
    if !textBytes.isEmpty {
        flags |= 1 << 1
    }
    var header = Data()
    header.append(ok ? 1 : 0)
    header.append(flags)
    header.append(contentsOf: [0, 0])
    header.append(runtimeControlI32BE(exitCode ?? 0))
    header.append(runtimeControlU32BE(UInt32(idBytes.count)))
    header.append(runtimeControlU32BE(UInt32(textBytes.count)))
    header.append(idBytes)
    header.append(textBytes)
    return header
}

private func runtimeControlEncodeBinaryProcReadHeader(
    ok: Bool,
    exitCode: Int32?,
    procID: String,
    text: String?,
    descriptors: [(stream: String, length: Int)]
) throws -> Data {
    let idBytes = Data(procID.utf8)
    let textBytes = Data((text ?? "").utf8)
    var flags: UInt8 = 0
    if exitCode != nil {
        flags |= 1 << 0
    }
    if !textBytes.isEmpty {
        flags |= 1 << 1
    }
    var header = Data()
    header.append(ok ? 1 : 0)
    header.append(flags)
    header.append(contentsOf: [0, 0])
    header.append(runtimeControlI32BE(exitCode ?? 0))
    header.append(runtimeControlU32BE(UInt32(idBytes.count)))
    header.append(runtimeControlU32BE(UInt32(textBytes.count)))
    header.append(runtimeControlU32BE(UInt32(descriptors.count)))
    header.append(idBytes)
    header.append(textBytes)
    for descriptor in descriptors {
        let streamID: UInt8
        switch descriptor.stream {
        case "stdout":
            streamID = RuntimeControlBinaryStreamKind.stdout.rawValue
        case "stderr":
            streamID = RuntimeControlBinaryStreamKind.stderr.rawValue
        default:
            streamID = 0
        }
        header.append(streamID)
        header.append(contentsOf: [0, 0, 0])
        header.append(runtimeControlU32BE(UInt32(descriptor.length)))
    }
    return header
}

private func runtimeControlDecodeBinaryPtyReadHeader(_ data: Data) throws -> RuntimeControlBinaryPtyReadHeader {
    guard data.count >= 16 else {
        throw MSLRuntimeError("short runtime control pty_read binary header")
    }
    let ok = data[0] == 1
    let flags = data[1]
    let exitCode = (flags & (1 << 0)) != 0 ? runtimeControlReadI32BE(data, offset: 4) : nil
    let idLength = Int(runtimeControlReadU32BE(data, offset: 8))
    let textLength = Int(runtimeControlReadU32BE(data, offset: 12))
    var offset = 16
    let id = try runtimeControlReadBinaryUTF8(data, offset: &offset, length: idLength)
    let text = textLength > 0 ? try runtimeControlReadBinaryUTF8(data, offset: &offset, length: textLength) : nil
    return RuntimeControlBinaryPtyReadHeader(ok: ok, exitCode: exitCode, id: id, text: text)
}

private func runtimeControlDecodeBinaryProcReadHeader(_ data: Data) throws -> RuntimeControlBinaryProcReadHeader {
    guard data.count >= 20 else {
        throw MSLRuntimeError("short runtime control proc_read binary header")
    }
    let ok = data[0] == 1
    let flags = data[1]
    let exitCode = (flags & (1 << 0)) != 0 ? runtimeControlReadI32BE(data, offset: 4) : nil
    let idLength = Int(runtimeControlReadU32BE(data, offset: 8))
    let textLength = Int(runtimeControlReadU32BE(data, offset: 12))
    let chunkCount = Int(runtimeControlReadU32BE(data, offset: 16))
    var offset = 20
    let procID = try runtimeControlReadBinaryUTF8(data, offset: &offset, length: idLength)
    let text = textLength > 0 ? try runtimeControlReadBinaryUTF8(data, offset: &offset, length: textLength) : nil
    var descriptors: [(stream: String, length: Int)] = []
    for _ in 0..<chunkCount {
        guard offset + 8 <= data.count else {
            throw MSLRuntimeError("short runtime control proc_read descriptor")
        }
        let streamID = data[offset]
        offset += 4
        let length = Int(runtimeControlReadU32BE(data, offset: offset))
        offset += 4
        let stream: String
        switch streamID {
        case RuntimeControlBinaryStreamKind.stdout.rawValue:
            stream = "stdout"
        case RuntimeControlBinaryStreamKind.stderr.rawValue:
            stream = "stderr"
        default:
            stream = "unknown"
        }
        descriptors.append((stream, length))
    }
    return RuntimeControlBinaryProcReadHeader(ok: ok, exitCode: exitCode, procID: procID, text: text, descriptors: descriptors)
}

func runtimeControlEncodeFrame(
    opcode: RuntimeControlFrameOpcode,
    header: Data,
    payload: Data
) throws -> Data {
    var data = Data()
    data.append(runtimeControlU32BE(runtimeControlFrameMagic))
    data.append(runtimeControlU32BE(opcode.rawValue))
    data.append(runtimeControlU32BE(UInt32(header.count)))
    data.append(runtimeControlU32BE(UInt32(payload.count)))
    data.append(header)
    data.append(payload)
    return data
}

private func runtimeControlDecodeFrame(_ data: Data) throws -> (opcode: RuntimeControlFrameOpcode, header: Data, payload: Data) {
    guard data.count >= 16 else {
        throw MSLRuntimeError("short runtime control frame")
    }
    let magic = runtimeControlReadU32BE(data, offset: 0)
    guard magic == runtimeControlFrameMagic else {
        throw MSLRuntimeError("invalid runtime control frame magic")
    }
    let opcodeValue = runtimeControlReadU32BE(data, offset: 4)
    guard let opcode = RuntimeControlFrameOpcode(rawValue: opcodeValue) else {
        throw MSLRuntimeError("unsupported runtime control frame opcode \(opcodeValue)")
    }
    let headerLength = Int(runtimeControlReadU32BE(data, offset: 8))
    let payloadLength = Int(runtimeControlReadU32BE(data, offset: 12))
    let expectedLength = 16 + headerLength + payloadLength
    guard data.count == expectedLength else {
        throw MSLRuntimeError("invalid runtime control frame length")
    }
    let headerStart = 16
    let payloadStart = headerStart + headerLength
    return (
        opcode,
        data.subdata(in: headerStart..<payloadStart),
        data.subdata(in: payloadStart..<expectedLength)
    )
}

private func runtimeControlReadExact(fd: Int32, byteCount: Int) throws -> Data {
    var buffer = Data(count: byteCount)
    var offset = 0
    try buffer.withUnsafeMutableBytes { raw in
        guard let base = raw.baseAddress else { return }
        while offset < byteCount {
            let n = read(fd, base + offset, byteCount - offset)
            if n == 0 {
                throw MSLRuntimeError("runtime control socket closed")
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw MSLRuntimeError("runtime control read failed: \(String(cString: strerror(errno)))")
            }
            offset += n
        }
    }
    return buffer
}

private func runtimeControlReadFrame(fd: Int32) throws -> Data {
    let prefix = try runtimeControlReadExact(fd: fd, byteCount: 16)
    let headerLength = Int(runtimeControlReadU32BE(prefix, offset: 8))
    let payloadLength = Int(runtimeControlReadU32BE(prefix, offset: 12))
    let remainder = try runtimeControlReadExact(fd: fd, byteCount: headerLength + payloadLength)
    var frame = Data()
    frame.append(prefix)
    frame.append(remainder)
    return frame
}

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
    public var procId: String?
    public var dataBase64: String?
    public var rawData: Data?
    public var rows: Int?
    public var cols: Int?
    public var sessionId: String?
    public var cwd: String?
    public var envAdditions: [String: String]?
    public var hostShareRoot: String?
    public var dnsSource: String?
    public var containerID: String?
    public var containerIDs: [String]?
    public var imageID: String?

    enum CodingKeys: String, CodingKey {
        case op
        case instance
        case all
        case callerCwd
        case hostPort
        case guestPort
        case argv
        case timeoutMs
        case runAsRoot
        case ptyId
        case procId
        case dataBase64
        case rows
        case cols
        case sessionId
        case cwd
        case envAdditions
        case hostShareRoot
        case dnsSource
        case containerID
        case containerIDs
        case imageID
    }

    public init(
        op: String,
        instance: String? = nil,
        all: Bool? = nil,
        callerCwd: String? = nil,
        hostPort: Int? = nil,
        guestPort: Int? = nil,
        argv: [String]? = nil,
        timeoutMs: Int? = nil,
        runAsRoot: Bool? = nil,
        ptyId: String? = nil,
        procId: String? = nil,
        dataBase64: String? = nil,
        rawData: Data? = nil,
        rows: Int? = nil,
        cols: Int? = nil,
        sessionId: String? = nil,
        cwd: String? = nil,
        envAdditions: [String: String]? = nil,
        hostShareRoot: String? = nil,
        dnsSource: String? = nil,
        containerID: String? = nil,
        containerIDs: [String]? = nil,
        imageID: String? = nil
    ) {
        self.op = op
        self.instance = instance
        self.all = all
        self.callerCwd = callerCwd
        self.hostPort = hostPort
        self.guestPort = guestPort
        self.argv = argv
        self.timeoutMs = timeoutMs
        self.runAsRoot = runAsRoot
        self.ptyId = ptyId
        self.procId = procId
        self.dataBase64 = dataBase64
        self.rawData = rawData
        self.rows = rows
        self.cols = cols
        self.sessionId = sessionId
        self.cwd = cwd
        self.envAdditions = envAdditions
        self.hostShareRoot = hostShareRoot
        self.dnsSource = dnsSource
        self.containerID = containerID
        self.containerIDs = containerIDs
        self.imageID = imageID
    }
}

public struct RuntimePortStatusItem: Codable {
    public var instance: String?
    public var hostPort: Int
    public var guestPort: Int
    public var bindAddress: String
    public var source: String?
    public var active: Bool
    public var ownerInstance: String?
    public var guestAddress: String?
    public var localhostEndpoint: String?
    public var hostnameEndpoint: String?
    public var directEndpoint: String?
    public var error: String?

    public init(
        instance: String? = nil,
        hostPort: Int,
        guestPort: Int,
        bindAddress: String,
        source: String? = nil,
        active: Bool,
        ownerInstance: String? = nil,
        guestAddress: String? = nil,
        localhostEndpoint: String? = nil,
        hostnameEndpoint: String? = nil,
        directEndpoint: String? = nil,
        error: String?
    ) {
        self.instance = instance
        self.hostPort = hostPort
        self.guestPort = guestPort
        self.bindAddress = bindAddress
        self.source = source
        self.active = active
        self.ownerInstance = ownerInstance
        self.guestAddress = guestAddress
        self.localhostEndpoint = localhostEndpoint
        self.hostnameEndpoint = hostnameEndpoint
        self.directEndpoint = directEndpoint
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

public struct RuntimeInstanceDetail: Codable {
    public var instance: String
    public var vmState: String
    public var lifecycleState: String
    public var activeSessionCount: Int
    public var uptimeSeconds: Int64?
    public var guestIPv4: String?
    public var portForwardCount: Int
    public var lastError: String?
    public var lastTransitionEpochMs: Int64

    public init(
        instance: String,
        vmState: String,
        lifecycleState: String,
        activeSessionCount: Int,
        uptimeSeconds: Int64?,
        guestIPv4: String?,
        portForwardCount: Int,
        lastError: String?,
        lastTransitionEpochMs: Int64
    ) {
        self.instance = instance
        self.vmState = vmState
        self.lifecycleState = lifecycleState
        self.activeSessionCount = activeSessionCount
        self.uptimeSeconds = uptimeSeconds
        self.guestIPv4 = guestIPv4
        self.portForwardCount = portForwardCount
        self.lastError = lastError
        self.lastTransitionEpochMs = lastTransitionEpochMs
    }
}

public struct RuntimeMemoryBreakdown: Codable {
    public var guestVisibleMemoryBytes: UInt64
    public var guestUsedBytes: UInt64
    public var guestAvailableBytes: UInt64
    public var kernelBufferCacheBytes: UInt64
    public var kernelOtherBytes: UInt64
    public var balloonTargetBytes: UInt64
    public var balloonMaxBytes: UInt64
    public var balloonReturnedTotalBytes: UInt64
    public var hostResidentMemoryBytes: UInt64?
}

public struct RuntimeCPUSnapshot: Codable {
    public var usagePercent: Double?
    public var logicalCPUCount: Int?
}

public struct RuntimeNetworkSnapshot: Codable {
    public var primaryInterface: String?
    public var rxBytes: UInt64
    public var txBytes: UInt64
    public var rxBytesPerSecond: Double?
    public var txBytesPerSecond: Double?
}

public struct RuntimeContainerRuntimeMetrics: Codable {
    public var containerdHealthy: Bool?
    public var buildkitdHealthy: Bool?
    public var dedupeEnabled: Bool?
    public var dedupeHealthy: Bool?
    public var dedupeDetail: String?
    public var containerCount: Int?
    public var imageCount: Int?
}

public struct RuntimeInstanceMetrics: Codable {
    public var sampledAtEpochMs: Int64
    public var memory: RuntimeMemoryBreakdown
    public var cpu: RuntimeCPUSnapshot
    public var network: RuntimeNetworkSnapshot
    public var containerRuntime: RuntimeContainerRuntimeMetrics?
}

public struct RuntimeStorageCompressionStats: Codable {
    public var hostLogicalBytes: UInt64?
    public var hostAllocatedBytes: UInt64?
    public var hostApparentBytes: UInt64?
    public var spaceSavingBytes: UInt64?
    public var spaceSavingRatio: Double?
    public var compressionCacheBytes: UInt64?
}

public struct RuntimeInstanceStorage: Codable {
    public var filesystem: String?
    public var mountPoint: String?
    public var totalBytes: UInt64?
    public var usedBytes: UInt64?
    public var availableBytes: UInt64?
    public var hostAllocatedBytes: UInt64?
    public var hostLogicalBytes: UInt64?
    public var hostApparentBytes: UInt64?
    public var compression: RuntimeStorageCompressionStats
}

public struct RuntimeProcessSnapshotItem: Codable, Identifiable {
    public var pid: Int
    public var user: String
    public var cpuPercent: Double
    public var memoryResidentBytes: UInt64
    public var command: String

    public var id: Int { pid }
}

public struct RuntimeContainerRuntimeSummary: Codable, Equatable {
    public var containerdHealthy: Bool?
    public var buildkitdHealthy: Bool?
    public var dedupeEnabled: Bool?
    public var dedupeHealthy: Bool?
    public var dedupeDetail: String?
    public var containerCount: Int?
    public var imageCount: Int?
    public var sampledAtEpochMs: Int64
}

public struct RuntimeContainerListItem: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var image: String
    public var command: String?
    public var created: String?
    public var status: String?
    public var state: String?
    public var ports: String?
    public var labels: [String: String]
    public var size: String?
}

public struct RuntimeContainerDetail: Codable, Equatable {
    public var id: String
    public var name: String
    public var image: String?
    public var state: String?
    public var status: String?
    public var created: String?
    public var command: String?
    public var ports: [String]
    public var mounts: [String]
    public var networks: [String]
    public var restartPolicy: String?
    public var envCount: Int?
    public var labels: [String: String]
}

public struct RuntimeContainerStats: Codable, Equatable {
    public var id: String
    public var name: String?
    public var cpuPercent: Double?
    public var memoryUsageBytes: UInt64?
    public var memoryLimitBytes: UInt64?
    public var memoryLimitUnlimited: Bool?
    public var networkRxBytes: UInt64?
    public var networkTxBytes: UInt64?
    public var blockReadBytes: UInt64?
    public var blockWriteBytes: UInt64?
    public var pids: Int?
    public var sampledAtEpochMs: Int64

    public var needsCgroupFallback: Bool {
        (memoryUsageBytes == 0 && memoryLimitBytes == 0)
            || (memoryUsageBytes == nil && memoryLimitBytes == nil)
    }
}

public struct RuntimeImageListItem: Codable, Equatable, Identifiable {
    public var id: String
    public var repository: String
    public var tag: String
    public var digest: String?
    public var created: String?
    public var size: String?
}

public struct RuntimeImageDetail: Codable, Equatable {
    public var id: String
    public var repoTags: [String]
    public var repoDigests: [String]
    public var architecture: String?
    public var os: String?
    public var created: String?
    public var sizeBytes: UInt64?
    public var labels: [String: String]
}

public struct RuntimeImageStorageSummary: Codable, Equatable {
    public var guestImageTotalBytes: UInt64?
    public var hostLogicalBytes: UInt64?
    public var hostAllocatedBytes: UInt64?
    public var sampledAtEpochMs: Int64

    public init(guestImageTotalBytes: UInt64?, hostLogicalBytes: UInt64?, hostAllocatedBytes: UInt64?, sampledAtEpochMs: Int64) {
        self.guestImageTotalBytes = guestImageTotalBytes
        self.hostLogicalBytes = hostLogicalBytes
        self.hostAllocatedBytes = hostAllocatedBytes
        self.sampledAtEpochMs = sampledAtEpochMs
    }
}

public struct RuntimeControlResponse: Codable {
    public var ok: Bool
    public var error: String?
    public var items: [RuntimePortStatusItem]?
    public var instances: [RuntimeInstanceStatusItem]?
    public var detail: RuntimeInstanceDetail?
    public var metrics: RuntimeInstanceMetrics?
    public var storage: RuntimeInstanceStorage?
    public var processes: [RuntimeProcessSnapshotItem]?
    public var containerRuntimeSummary: RuntimeContainerRuntimeSummary?
    public var containers: [RuntimeContainerListItem]?
    public var containerDetail: RuntimeContainerDetail?
    public var containerStats: RuntimeContainerStats?
    public var containerStatsList: [RuntimeContainerStats]?
    public var images: [RuntimeImageListItem]?
    public var imageDetail: RuntimeImageDetail?
    public var imageStorageSummary: RuntimeImageStorageSummary?
    // exec / pty / session responses
    public var stdout: String?
    public var stderr: String?
    public var exitCode: Int32?
    public var ptyId: String?
    public var procId: String?
    public var dataBase64: String?
    public var stdoutBase64: String?
    public var stderrBase64: String?
    public var chunks: [RuntimeControlStreamChunk]?
    public var sessionId: String?
    public var meta: [String: String]?
    public var rawData: Data? = nil
    public var rawStdout: Data? = nil
    public var rawStderr: Data? = nil

    enum CodingKeys: String, CodingKey {
        case ok
        case error
        case items
        case instances
        case detail
        case metrics
        case storage
        case processes
        case containerRuntimeSummary
        case containers
        case containerDetail
        case containerStats
        case containerStatsList
        case images
        case imageDetail
        case imageStorageSummary
        case stdout
        case stderr
        case exitCode
        case ptyId
        case procId
        case dataBase64
        case stdoutBase64
        case stderrBase64
        case chunks
        case sessionId
        case meta
    }
}

public struct RuntimeControlStreamChunk: Codable {
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

public enum RuntimeControlProcEventKind: String, Codable {
    case stdout
    case stderr
    case exited
    case streamsClosed = "streams_closed"
}

public struct RuntimeControlProcEvent {
    public var procId: String
    public var kind: RuntimeControlProcEventKind
    public var data: Data
    public var exitCode: Int32?
    public var text: String?
}

public enum RuntimeControlPtyEventKind: String, Codable {
    case output
    case exited
    case streamsClosed = "streams_closed"
}

public struct RuntimeControlPtyEvent {
    public var ptyId: String
    public var kind: RuntimeControlPtyEventKind
    public var data: Data
    public var exitCode: Int32?
    public var text: String?
}

struct RuntimeControlEventHeader: Codable {
    var kind: String
    var ptyId: String?
    var procId: String?
    var exitCode: Int32?
    var text: String?
}

public final class RuntimeControlProcEventStream {
    private let fd: Int32

    init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        _ = close(fd)
    }

    var fileDescriptor: Int32 { fd }

    public func nextEvent() throws -> RuntimeControlProcEvent? {
        let frameData = try runtimeControlReadFrame(fd: fd)
        let frame = try runtimeControlDecodeFrame(frameData)
        guard frame.opcode == .procEvent else {
            throw MSLRuntimeError("unexpected runtime control proc event opcode \(frame.opcode.rawValue)")
        }
        let header = try JSONDecoder().decode(RuntimeControlEventHeader.self, from: frame.header)
        guard let procId = header.procId,
              let kind = RuntimeControlProcEventKind(rawValue: header.kind) else {
            throw MSLRuntimeError("invalid runtime control proc event header")
        }
        return RuntimeControlProcEvent(
            procId: procId,
            kind: kind,
            data: frame.payload,
            exitCode: header.exitCode,
            text: header.text
        )
    }
}

public final class RuntimeControlPtyEventStream {
    private let fd: Int32

    init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        _ = close(fd)
    }

    var fileDescriptor: Int32 { fd }

    public func nextEvent() throws -> RuntimeControlPtyEvent? {
        let frameData = try runtimeControlReadFrame(fd: fd)
        let frame = try runtimeControlDecodeFrame(frameData)
        guard frame.opcode == .ptyEvent else {
            throw MSLRuntimeError("unexpected runtime control pty event opcode \(frame.opcode.rawValue)")
        }
        let header = try JSONDecoder().decode(RuntimeControlEventHeader.self, from: frame.header)
        guard let ptyId = header.ptyId,
              let kind = RuntimeControlPtyEventKind(rawValue: header.kind) else {
            throw MSLRuntimeError("invalid runtime control pty event header")
        }
        return RuntimeControlPtyEvent(
            ptyId: ptyId,
            kind: kind,
            data: frame.payload,
            exitCode: header.exitCode,
            text: header.text
        )
    }
}

final class RuntimeControlServer {
    private let socketPath: String
    private let handler: (RuntimeControlRequest) -> RuntimeControlResponse
    private let streamHandler: ((RuntimeControlRequest, Int32) -> Bool)?
    private var listenFD: Int32 = -1
    private var thread: Thread?
    private var running = false

    init(
        socketPath: String,
        handler: @escaping (RuntimeControlRequest) -> RuntimeControlResponse,
        streamHandler: ((RuntimeControlRequest, Int32) -> Bool)? = nil
    ) {
        self.socketPath = socketPath
        self.handler = handler
        self.streamHandler = streamHandler
    }

    func start() throws {
        if running { return }
        try removeSocketIfExists()

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        if listenFD < 0 {
            throw MSLRuntimeError("failed to create runtime control socket: \(lastErr())")
        }
        try runtimeControlConfigureNoSigPipe(fd: listenFD)

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
            do {
                try runtimeControlConfigureNoSigPipe(fd: clientFD)
            } catch {
                _ = close(clientFD)
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
        while running {
            guard let frame = try? runtimeControlReadFrame(fd: fd) else {
                break  // connection closed or error
            }
            do {
                try handleFrame(frame, to: fd)
            } catch {
                break
            }
        }
    }

    private func handleFrame(_ frameData: Data, to fd: Int32) throws {
        let frame = try runtimeControlDecodeFrame(frameData)
        switch frame.opcode {
        case .jsonRPCRequest:
            let request = try JSONDecoder().decode(RuntimeControlRequest.self, from: frame.payload)
            let response = handler(request)
            let payload = try JSONEncoder().encode(response)
            let responseFrame = try runtimeControlEncodeFrame(opcode: .jsonRPCResponse, header: Data(), payload: payload)
            try runtimeControlWriteAll(fd: fd, data: responseFrame)
        case .ptyReadRequest:
            let request = try makeDirectReadRequest(header: frame.header, op: "pty_read")
            let response = handler(request)
            let responseFrame = try makeDirectPtyReadResponseFrame(response)
            try runtimeControlWriteAll(fd: fd, data: responseFrame)
        case .ptyWriteRequest:
            let request = try makeDirectWriteRequest(header: frame.header, payload: frame.payload, op: "pty_write")
            let response = handler(request)
            let responseFrame = try makeDirectAckResponseFrame(response, opcode: .ptyWriteResponse)
            try runtimeControlWriteAll(fd: fd, data: responseFrame)
        case .procReadRequest:
            let request = try makeDirectReadRequest(header: frame.header, op: "proc_read")
            let response = handler(request)
            let responseFrame = try makeDirectProcReadResponseFrame(response)
            try runtimeControlWriteAll(fd: fd, data: responseFrame)
        case .procWriteRequest:
            let request = try makeDirectWriteRequest(header: frame.header, payload: frame.payload, op: "proc_write")
            let response = handler(request)
            let responseFrame = try makeDirectAckResponseFrame(response, opcode: .procWriteResponse)
            try runtimeControlWriteAll(fd: fd, data: responseFrame)
        case .procWriteAsyncRequest:
            let request = try makeDirectWriteRequest(header: frame.header, payload: frame.payload, op: "proc_write")
            _ = handler(request)
        case .procSubscribeRequest:
            guard let streamHandler else {
                throw MSLRuntimeError("runtime control proc_subscribe unsupported")
            }
            let request = try makeDirectSubscribeRequest(header: frame.header, op: "proc_subscribe")
            guard streamHandler(request, fd) else {
                throw MSLRuntimeError("runtime control proc_subscribe failed")
            }
        case .ptySubscribeRequest:
            guard let streamHandler else {
                throw MSLRuntimeError("runtime control pty_subscribe unsupported")
            }
            let request = try makeDirectSubscribeRequest(header: frame.header, op: "pty_subscribe")
            guard streamHandler(request, fd) else {
                throw MSLRuntimeError("runtime control pty_subscribe failed")
            }
        default:
            throw MSLRuntimeError("unsupported runtime control request opcode \(frame.opcode.rawValue)")
        }
    }

    private func makeDirectReadRequest(header: Data, op: String) throws -> RuntimeControlRequest {
        let direct = try JSONDecoder().decode(RuntimeControlDirectHeader.self, from: header)
        return RuntimeControlRequest(
            op: direct.op.isEmpty ? op : direct.op,
            timeoutMs: direct.timeoutMs,
            ptyId: direct.ptyId,
            procId: direct.procId
        )
    }

    private func makeDirectWriteRequest(header: Data, payload: Data, op: String) throws -> RuntimeControlRequest {
        let direct = try JSONDecoder().decode(RuntimeControlDirectHeader.self, from: header)
        return RuntimeControlRequest(
            op: direct.op.isEmpty ? op : direct.op,
            timeoutMs: direct.timeoutMs,
            ptyId: direct.ptyId,
            procId: direct.procId,
            rawData: payload
        )
    }

    private func makeDirectSubscribeRequest(header: Data, op: String) throws -> RuntimeControlRequest {
        let direct = try JSONDecoder().decode(RuntimeControlDirectHeader.self, from: header)
        return RuntimeControlRequest(
            op: direct.op.isEmpty ? op : direct.op,
            ptyId: direct.ptyId,
            procId: direct.procId,
            sessionId: nil
        )
    }

    private func makeDirectAckResponseFrame(
        _ response: RuntimeControlResponse,
        opcode: RuntimeControlFrameOpcode
    ) throws -> Data {
        let header = RuntimeControlDirectHeader(
            op: response.procId != nil ? "proc_write" : (response.ptyId != nil ? "pty_write" : ""),
            status: response.ok ? "ok" : "error",
            error: response.error,
            exitCode: response.exitCode,
            ptyId: response.ptyId,
            procId: response.procId,
            timeoutMs: nil,
            meta: response.meta,
            chunks: nil
        )
        return try runtimeControlEncodeFrame(
            opcode: opcode,
            header: try JSONEncoder().encode(header),
            payload: Data()
        )
    }

    private func makeDirectPtyReadResponseFrame(_ response: RuntimeControlResponse) throws -> Data {
        let header = try runtimeControlEncodeBinaryPtyReadHeader(
            ok: response.ok,
            exitCode: response.exitCode,
            id: response.ptyId ?? "",
            text: response.ok ? nil : response.error
        )
        let payload = response.rawData ?? (Data(base64Encoded: response.dataBase64 ?? "") ?? Data())
        return try runtimeControlEncodeFrame(
            opcode: .ptyReadResponse,
            header: header,
            payload: payload
        )
    }

    private func makeDirectProcReadResponseFrame(_ response: RuntimeControlResponse) throws -> Data {
        var payload = Data()
        var descriptors: [(stream: String, length: Int)] = []
        if let chunks = response.chunks, !chunks.isEmpty {
            for chunk in chunks {
                let data = chunk.rawData ?? (Data(base64Encoded: chunk.dataBase64) ?? Data())
                descriptors.append((stream: chunk.stream, length: data.count))
                payload.append(data)
            }
        } else {
            let stdout = response.rawStdout ?? (Data(base64Encoded: response.stdoutBase64 ?? "") ?? Data())
            let stderr = response.rawStderr ?? (Data(base64Encoded: response.stderrBase64 ?? "") ?? Data())
            if !stdout.isEmpty {
                descriptors.append((stream: "stdout", length: stdout.count))
                payload.append(stdout)
            }
            if !stderr.isEmpty {
                descriptors.append((stream: "stderr", length: stderr.count))
                payload.append(stderr)
            }
        }
        let exitReason = response.meta?["exitReason"] ?? (response.ok ? nil : response.error)
        let header = try runtimeControlEncodeBinaryProcReadHeader(
            ok: response.ok,
            exitCode: response.exitCode,
            procID: response.procId ?? "",
            text: exitReason,
            descriptors: descriptors
        )
        return try runtimeControlEncodeFrame(
            opcode: .procReadResponse,
            header: header,
            payload: payload
        )
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

public final class RuntimeControlClient {
    private let socketPath: String
    private var persistentFD: Int32 = -1
    private let connectTimeoutMs: Int32 = 250

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    deinit {
        disconnect()
    }

    /// Single-shot send: connect, send, receive, disconnect.
    public func send(_ request: RuntimeControlRequest) throws -> RuntimeControlResponse {
        let fd = try connectOnce()
        defer { _ = close(fd) }
        return try sendOnFD(request, fd: fd)
    }

    /// Establish a persistent connection for multiple request-response pairs.
    func connect() throws {
        if persistentFD >= 0 { return }
        persistentFD = try connectOnce()
    }

    /// Send a request on the persistent connection.
    func sendPersistent(_ request: RuntimeControlRequest) throws -> RuntimeControlResponse {
        guard persistentFD >= 0 else {
            throw MSLRuntimeError("not connected to daemon control socket")
        }
        return try sendOnFD(request, fd: persistentFD, persistent: true)
    }

    /// Send a request on the persistent connection without expecting a response.
    /// Only valid for fire-and-forget direct opcodes such as async proc_write.
    func sendPersistentNoReply(_ request: RuntimeControlRequest) throws {
        guard persistentFD >= 0 else {
            throw MSLRuntimeError("not connected to daemon control socket")
        }
        let frame = try makeRequestFrame(request, noReply: true)
        try runtimeControlWriteAll(fd: persistentFD, data: frame)
    }

    /// Close the persistent connection.
    func disconnect() {
        if persistentFD >= 0 {
            _ = close(persistentFD)
            persistentFD = -1
        }
    }

    private func sendOnFD(_ request: RuntimeControlRequest, fd: Int32, persistent: Bool = false) throws -> RuntimeControlResponse {
        let frame = try makeRequestFrame(request)
        try runtimeControlWriteAll(fd: fd, data: frame)
        let responseFrame = try runtimeControlReadFrame(fd: fd)
        return try decodeResponseFrame(responseFrame)
    }

    private func connectOnce() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 {
            throw MSLRuntimeError("failed to create control client socket: \(String(cString: strerror(errno)))")
        }
        try runtimeControlConfigureNoSigPipe(fd: fd)

        let originalFlags = fcntl(fd, F_GETFL)
        if originalFlags < 0 {
            _ = close(fd)
            throw MSLRuntimeError("failed to get control client socket flags: \(String(cString: strerror(errno)))")
        }
        if fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) != 0 {
            _ = close(fd)
            throw MSLRuntimeError("failed to configure control client socket: \(String(cString: strerror(errno)))")
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
            if errno != EINPROGRESS {
                _ = close(fd)
                throw MSLRuntimeError("runtime control socket unavailable")
            }
            var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            while true {
                let result = poll(&pollFD, 1, connectTimeoutMs)
                if result > 0 {
                    var socketError: Int32 = 0
                    var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
                    if getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &socketErrorLength) != 0 {
                        _ = close(fd)
                        throw MSLRuntimeError("runtime control socket unavailable")
                    }
                    if socketError != 0 {
                        _ = close(fd)
                        throw MSLRuntimeError("runtime control socket unavailable")
                    }
                    break
                }
                if result == 0 {
                    _ = close(fd)
                    throw MSLRuntimeError("runtime control socket unavailable")
                }
                if errno == EINTR {
                    continue
                }
                _ = close(fd)
                throw MSLRuntimeError("runtime control socket unavailable")
            }
        }

        if fcntl(fd, F_SETFL, originalFlags) != 0 {
            _ = close(fd)
            throw MSLRuntimeError("failed to restore control client socket flags: \(String(cString: strerror(errno)))")
        }
        return fd
    }

    func procSubscribe(procId: String) throws -> RuntimeControlProcEventStream {
        let fd = try connectOnce()
        do {
            let frame = try runtimeControlEncodeFrame(
                opcode: .procSubscribeRequest,
                header: try JSONEncoder().encode(RuntimeControlDirectHeader(
                    op: "proc_subscribe",
                    status: nil,
                    error: nil,
                    exitCode: nil,
                    ptyId: nil,
                    procId: procId,
                    timeoutMs: nil,
                    meta: nil,
                    chunks: nil
                )),
                payload: Data()
            )
            try runtimeControlWriteAll(fd: fd, data: frame)
            return RuntimeControlProcEventStream(fd: fd)
        } catch {
            _ = close(fd)
            throw error
        }
    }

    func ptySubscribe(ptyId: String) throws -> RuntimeControlPtyEventStream {
        let fd = try connectOnce()
        do {
            let frame = try runtimeControlEncodeFrame(
                opcode: .ptySubscribeRequest,
                header: try JSONEncoder().encode(RuntimeControlDirectHeader(
                    op: "pty_subscribe",
                    status: nil,
                    error: nil,
                    exitCode: nil,
                    ptyId: ptyId,
                    procId: nil,
                    timeoutMs: nil,
                    meta: nil,
                    chunks: nil
                )),
                payload: Data()
            )
            try runtimeControlWriteAll(fd: fd, data: frame)
            return RuntimeControlPtyEventStream(fd: fd)
        } catch {
            _ = close(fd)
            throw error
        }
    }

    private func makeRequestFrame(_ request: RuntimeControlRequest, noReply: Bool = false) throws -> Data {
        switch request.op {
        case "pty_read":
            return try runtimeControlEncodeFrame(
                opcode: .ptyReadRequest,
                header: try JSONEncoder().encode(RuntimeControlDirectHeader(
                    op: request.op,
                    status: nil,
                    error: nil,
                    exitCode: nil,
                    ptyId: request.ptyId,
                    procId: nil,
                    timeoutMs: request.timeoutMs,
                    meta: nil,
                    chunks: nil
                )),
                payload: Data()
            )
        case "pty_write":
            return try runtimeControlEncodeFrame(
                opcode: .ptyWriteRequest,
                header: try JSONEncoder().encode(RuntimeControlDirectHeader(
                    op: request.op,
                    status: nil,
                    error: nil,
                    exitCode: nil,
                    ptyId: request.ptyId,
                    procId: nil,
                    timeoutMs: request.timeoutMs,
                    meta: nil,
                    chunks: nil
                )),
                payload: request.rawData ?? (Data(base64Encoded: request.dataBase64 ?? "") ?? Data())
            )
        case "proc_read":
            return try runtimeControlEncodeFrame(
                opcode: .procReadRequest,
                header: try JSONEncoder().encode(RuntimeControlDirectHeader(
                    op: request.op,
                    status: nil,
                    error: nil,
                    exitCode: nil,
                    ptyId: nil,
                    procId: request.procId,
                    timeoutMs: request.timeoutMs,
                    meta: nil,
                    chunks: nil
                )),
                payload: Data()
            )
        case "proc_write":
            return try runtimeControlEncodeFrame(
                opcode: noReply ? .procWriteAsyncRequest : .procWriteRequest,
                header: try JSONEncoder().encode(RuntimeControlDirectHeader(
                    op: request.op,
                    status: nil,
                    error: nil,
                    exitCode: nil,
                    ptyId: nil,
                    procId: request.procId,
                    timeoutMs: request.timeoutMs,
                    meta: nil,
                    chunks: nil
                )),
                payload: request.rawData ?? (Data(base64Encoded: request.dataBase64 ?? "") ?? Data())
            )
        default:
            return try runtimeControlEncodeFrame(
                opcode: .jsonRPCRequest,
                header: Data(),
                payload: try JSONEncoder().encode(request)
            )
        }
    }

    private func decodeResponseFrame(_ frameData: Data) throws -> RuntimeControlResponse {
        let frame = try runtimeControlDecodeFrame(frameData)
        switch frame.opcode {
        case .jsonRPCResponse:
            return try JSONDecoder().decode(RuntimeControlResponse.self, from: frame.payload)
        case .ptyReadResponse:
            let header = try runtimeControlDecodeBinaryPtyReadHeader(frame.header)
            return RuntimeControlResponse(
                ok: header.ok,
                error: header.ok ? nil : header.text,
                exitCode: header.exitCode,
                ptyId: header.id,
                dataBase64: frame.payload.isEmpty ? nil : frame.payload.base64EncodedString(),
                meta: header.exitCode == nil ? nil : ["exitCode": String(header.exitCode!)],
                rawData: frame.payload
            )
        case .ptyWriteResponse, .procWriteResponse:
            let header = try JSONDecoder().decode(RuntimeControlDirectHeader.self, from: frame.header)
            return RuntimeControlResponse(
                ok: (header.status ?? "ok") == "ok",
                error: header.error,
                exitCode: header.exitCode,
                ptyId: header.ptyId,
                procId: header.procId,
                meta: header.meta
            )
        case .procReadResponse:
            let header = try runtimeControlDecodeBinaryProcReadHeader(frame.header)
            var stdout = Data()
            var stderr = Data()
            var chunks: [RuntimeControlStreamChunk] = []
            var offset = 0
            for descriptor in header.descriptors {
                guard descriptor.length >= 0, offset + descriptor.length <= frame.payload.count else {
                    throw MSLRuntimeError("invalid runtime control proc_read chunk layout")
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
                var chunkEntry = RuntimeControlStreamChunk(stream: descriptor.stream, dataBase64: chunk.base64EncodedString())
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
            return RuntimeControlResponse(
                ok: header.ok,
                error: header.ok ? nil : header.text,
                exitCode: header.exitCode,
                procId: header.procID,
                stdoutBase64: stdout.isEmpty ? nil : stdout.base64EncodedString(),
                stderrBase64: stderr.isEmpty ? nil : stderr.base64EncodedString(),
                chunks: chunks.isEmpty ? nil : chunks,
                meta: meta,
                rawStdout: stdout.isEmpty ? nil : stdout,
                rawStderr: stderr.isEmpty ? nil : stderr
            )
        default:
            throw MSLRuntimeError("unexpected runtime control frame opcode \(frame.opcode.rawValue)")
        }
    }
}
