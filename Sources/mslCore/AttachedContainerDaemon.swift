import Foundation
import Darwin

let attachedDockerAPIVersion = "1.51"
let attachedDockerMinAPIVersion = "1.44"
let attachedDockerServerHeader = "Docker/28.3.2 (linux)"

enum AttachedHTTPResponseTransferMode {
    case contentLength
    case chunked
}

func attachedHTTPDateHeaderValue(now: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
    return formatter.string(from: now)
}

func attachedHTTPResponseHeader(
    status: Int,
    contentType: String,
    bodyLength: Int,
    transferMode: AttachedHTTPResponseTransferMode,
    now: Date = Date()
) -> String {
    let reason: String
    switch status {
    case 200: reason = "OK"
    case 201: reason = "Created"
    case 400: reason = "Bad Request"
    case 404: reason = "Not Found"
    case 500: reason = "Internal Server Error"
    default: reason = "Error"
    }
    var header = "HTTP/1.1 \(status) \(reason)\r\n" +
        "Content-Type: \(contentType)\r\n" +
        "Api-Version: \(attachedDockerAPIVersion)\r\n" +
        "Date: \(attachedHTTPDateHeaderValue(now: now))\r\n" +
        "Docker-Experimental: false\r\n" +
        "Ostype: linux\r\n" +
        "Server: \(attachedDockerServerHeader)\r\n"
    switch transferMode {
    case .contentLength:
        header += "Content-Length: \(bodyLength)\r\n"
    case .chunked:
        header += "Transfer-Encoding: chunked\r\n"
    }
    header += "\r\n"
    return header
}

struct AttachedContainerDescriptor: Codable, Equatable {
    var instance: String
    var vmID: String
    var name: String
    var image: String
    var running: Bool
    var platform: String
    var defaultUser: String
    var defaultHome: String
    var defaultShell: String
}

extension AttachedContainerDescriptor {
    var containerID: String {
        AttachedContainerIdentity.containerID(forInstance: instance)
    }

    var imageID: String {
        AttachedContainerIdentity.imageID(forInstance: instance)
    }

    var imageDigest: String {
        AttachedContainerIdentity.imageDigest(forInstance: instance)
    }

    var networkID: String {
        AttachedContainerIdentity.networkID(forInstance: instance)
    }

    var sandboxID: String {
        AttachedContainerIdentity.sandboxID(forInstance: instance)
    }

    var endpointID: String {
        AttachedContainerIdentity.endpointID(forInstance: instance)
    }

    var macAddress: String {
        AttachedContainerIdentity.macAddress(forInstance: instance)
    }

    private var imageManifestDescriptor: [String: Any] {
        [
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "digest": imageDigest,
            "size": 1025,
            "annotations": [
                "com.docker.official-images.bashbrew.arch": "arm64v8",
                "org.opencontainers.image.base.name": "scratch",
                "org.opencontainers.image.created": "2026-01-28T01:17:47Z",
                "org.opencontainers.image.revision": "msl-attached-template",
                "org.opencontainers.image.source": "https://github.com/shibukawa/msl",
                "org.opencontainers.image.url": "https://github.com/shibukawa/msl",
                "org.opencontainers.image.version": "attached-1"
            ],
            "platform": [
                "architecture": "arm64",
                "os": "linux",
                "variant": "v8"
            ]
        ]
    }

    func containerSummaryJSON() -> [String: Any] {
        [
            "Id": containerID,
            "Names": ["/\(name)"],
            "Image": image,
            "ImageID": imageID,
            "ImageManifestDescriptor": imageManifestDescriptor,
            "Command": "/bin/sh",
            "Created": 1_772_807_073,
            "Ports": NSNull(),
            "Labels": [
                "desktop.docker.io/ports.scheme": "v2"
            ],
            "State": running ? "running" : "exited",
            "Status": running ? "Up 12 seconds" : "Exited (0)",
            "HostConfig": [
                "NetworkMode": "bridge"
            ],
            "NetworkSettings": [
                "Networks": [
                    "bridge": [
                        "IPAMConfig": NSNull(),
                        "Links": NSNull(),
                        "Aliases": NSNull(),
                        "MacAddress": macAddress,
                        "DriverOpts": NSNull(),
                        "GwPriority": 0,
                        "NetworkID": networkID,
                        "EndpointID": endpointID,
                        "Gateway": "172.17.0.1",
                        "IPAddress": "172.17.0.2",
                        "IPPrefixLen": 16,
                        "IPv6Gateway": "",
                        "GlobalIPv6Address": "",
                        "GlobalIPv6PrefixLen": 0,
                        "DNSNames": NSNull()
                    ]
                ]
            ],
            "Mounts": []
        ]
    }

    func inspectJSON(execIDs: [String]) -> [String: Any] {
        let stateStatus = running ? "running" : "exited"
        let emptyObject: [String: Any] = [:]
        let defaultPATH = "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        let maskedPaths = [
            "/proc/asound",
            "/proc/acpi",
            "/proc/interrupts",
            "/proc/kcore",
            "/proc/keys",
            "/proc/latency_stats",
            "/proc/timer_list",
            "/proc/timer_stats",
            "/proc/sched_debug",
            "/proc/scsi",
            "/sys/firmware",
            "/sys/devices/virtual/powercap"
        ]
        let readonlyPaths = [
            "/proc/bus",
            "/proc/fs",
            "/proc/irq",
            "/proc/sys",
            "/proc/sysrq-trigger"
        ]
        return [
            "Id": containerID,
            "Created": "2026-03-06T14:24:33.900418625Z",
            "Driver": "overlayfs",
            "ExecIDs": execIDs.isEmpty ? NSNull() : execIDs,
            "GraphDriver": [
                "Name": "overlayfs",
                "Data": NSNull()
            ],
            "ResolvConfPath": "/var/lib/docker/containers/\(containerID)/resolv.conf",
            "HostnamePath": "/var/lib/docker/containers/\(containerID)/hostname",
            "HostsPath": "/var/lib/docker/containers/\(containerID)/hosts",
            "LogPath": "/var/lib/docker/containers/\(containerID)/\(containerID)-json.log",
            "Name": "/\(name)",
            "RestartCount": 0,
            "Platform": platform,
            "Path": "/bin/sh",
            "Args": [],
            "Image": imageID,
            "MountLabel": "",
            "ProcessLabel": "",
            "AppArmorProfile": "",
            "Config": [
                "Hostname": String(containerID.prefix(12)),
                "Domainname": "",
                "Image": image,
                "User": defaultUser == "root" ? "" : defaultUser,
                "AttachStdin": false,
                "AttachStdout": false,
                "AttachStderr": false,
                "Tty": false,
                "OpenStdin": false,
                "StdinOnce": false,
                "Env": [
                    defaultPATH,
                    "SHELL=\(defaultShell)",
                    "HOME=\(defaultHome)",
                    "USER=\(defaultUser)"
                ],
                "Cmd": ["/bin/sh"],
                "WorkingDir": defaultHome,
                "Entrypoint": NSNull(),
                "OnBuild": NSNull(),
                "Volumes": NSNull(),
                "Labels": emptyObject
            ],
            "State": [
                "Status": stateStatus,
                "Running": running,
                "Paused": false,
                "Restarting": false,
                "OOMKilled": false,
                "Dead": false,
                "Pid": 1,
                "ExitCode": 0,
                "Error": "",
                "StartedAt": "2026-01-01T00:00:00Z",
                "FinishedAt": "0001-01-01T00:00:00Z"
            ],
            "HostConfig": [
                "Binds": NSNull(),
                "ContainerIDFile": "",
                "LogConfig": [
                    "Type": "json-file",
                    "Config": emptyObject
                ],
                "NetworkMode": "bridge",
                "PortBindings": emptyObject,
                "RestartPolicy": [
                    "Name": "no",
                    "MaximumRetryCount": 0
                ],
                "AutoRemove": false,
                "VolumeDriver": "",
                "VolumesFrom": NSNull(),
                "ConsoleSize": [0, 0],
                "CapAdd": NSNull(),
                "CapDrop": NSNull(),
                "CgroupnsMode": "private",
                "Dns": [],
                "DnsOptions": [],
                "DnsSearch": [],
                "ExtraHosts": NSNull(),
                "GroupAdd": NSNull(),
                "IpcMode": "private",
                "Cgroup": "",
                "Links": NSNull(),
                "OomScoreAdj": 0,
                "PidMode": "",
                "Privileged": false,
                "PublishAllPorts": false,
                "ReadonlyRootfs": false,
                "SecurityOpt": NSNull(),
                "UTSMode": "",
                "UsernsMode": "",
                "ShmSize": 67108864,
                "Runtime": "runc",
                "Isolation": "",
                "CpuShares": 0,
                "Memory": 0,
                "NanoCpus": 0,
                "CgroupParent": "",
                "BlkioWeight": 0,
                "BlkioWeightDevice": [],
                "BlkioDeviceReadBps": [],
                "BlkioDeviceWriteBps": [],
                "BlkioDeviceReadIOps": [],
                "BlkioDeviceWriteIOps": [],
                "CpuPeriod": 0,
                "CpuQuota": 0,
                "CpuRealtimePeriod": 0,
                "CpuRealtimeRuntime": 0,
                "CpusetCpus": "",
                "CpusetMems": "",
                "Devices": [],
                "DeviceCgroupRules": NSNull(),
                "DeviceRequests": NSNull(),
                "MemoryReservation": 0,
                "MemorySwap": 0,
                "MemorySwappiness": NSNull(),
                "OomKillDisable": NSNull(),
                "PidsLimit": NSNull(),
                "Ulimits": [],
                "CpuCount": 0,
                "CpuPercent": 0,
                "IOMaximumIOps": 0,
                "IOMaximumBandwidth": 0,
                "MaskedPaths": maskedPaths,
                "ReadonlyPaths": readonlyPaths
            ],
            "Mounts": [],
            "NetworkSettings": [
                "Bridge": "",
                "SandboxID": sandboxID,
                "SandboxKey": "/var/run/docker/netns/\(String(sandboxID.prefix(12)))",
                "Ports": [:],
                "HairpinMode": false,
                "LinkLocalIPv6Address": "",
                "LinkLocalIPv6PrefixLen": 0,
                "SecondaryIPAddresses": NSNull(),
                "SecondaryIPv6Addresses": NSNull(),
                "EndpointID": endpointID,
                "Gateway": "172.17.0.1",
                "GlobalIPv6Address": "",
                "GlobalIPv6PrefixLen": 0,
                "IPAddress": "172.17.0.2",
                "IPPrefixLen": 16,
                "IPv6Gateway": "",
                "MacAddress": macAddress,
                "Networks": [
                    "bridge": [
                        "IPAMConfig": NSNull(),
                        "Links": NSNull(),
                        "Aliases": NSNull(),
                        "MacAddress": macAddress,
                        "DriverOpts": NSNull(),
                        "GwPriority": 0,
                        "NetworkID": networkID,
                        "EndpointID": endpointID,
                        "Gateway": "172.17.0.1",
                        "IPAddress": "172.17.0.2",
                        "IPPrefixLen": 16,
                        "IPv6Gateway": "",
                        "GlobalIPv6Address": "",
                        "GlobalIPv6PrefixLen": 0,
                        "DNSNames": NSNull()
                    ]
                ]
            ],
            "ImageManifestDescriptor": imageManifestDescriptor
        ]
    }
}

struct AttachedExecSession {
    var execID: String
    var instance: String
    var vmID: String
    var containerID: String
    var cmd: [String]
    var workingDir: String?
    var tty: Bool
    var attachStdin: Bool
    var attachStdout: Bool
    var attachStderr: Bool
    var detachKeys: String
    var user: String
    var envAdditions: [String: String]
    var privileged: Bool
    var running: Bool
    var exitCode: Int?
    var pid: Int?
    var createdAtEpochMs: Int64

    var processConfigJSON: [String: Any] {
        let entrypoint = cmd.first ?? "/bin/sh"
        let arguments = Array(cmd.dropFirst()).joined(separator: " ")
        return [
            "tty": tty,
            "entrypoint": entrypoint,
            "arguments": arguments,
            "privileged": privileged,
            "user": user
        ]
    }

    func inspectJSON() -> [String: Any] {
        [
            "ID": execID,
            "Running": running,
            "ExitCode": exitCode ?? 0,
            "ProcessConfig": processConfigJSON,
            "OpenStdin": attachStdin,
            "OpenStdout": attachStdout,
            "OpenStderr": attachStderr,
            "CanRemove": false,
            "ContainerID": containerID,
            "DetachKeys": detachKeys,
            "Pid": pid ?? 0
        ]
    }
}

enum AttachedExecKind: String {
    case interactive
    case helperShell = "helper_shell"
    case userEnvProbe = "user_env_probe"
    case watchInstalledExtensions = "watch_installed_extensions"
    case watchMachineSettings = "watch_machine_settings"
    case extensionInstall = "extension_install"
    case extensionSync = "extension_sync"
    case backgroundProbe = "background_probe"
    case other
}

func attachedExecKind(session: AttachedExecSession) -> AttachedExecKind {
    if session.tty {
        return .interactive
    }

    let joined = session.cmd.joined(separator: " ")
    if session.cmd.first == "/bin/sh", session.cmd.count == 1 {
        return .helperShell
    }
    if joined.contains("# Watch installed extensions") {
        return .watchInstalledExtensions
    }
    if joined.contains("# Watch machine settings") {
        return .watchMachineSettings
    }
    if joined.contains("cat /proc/self/environ") || joined.contains("printenv") {
        return .userEnvProbe
    }
    if joined.contains("cd /proc && ls -d [0-9]*") {
        return .backgroundProbe
    }
    if joined.contains("dd iflag=fullblock") && joined.contains("tar --no-same-owner -xz -C") {
        return .extensionInstall
    }
    if joined.contains("tar c extensionsCache/") || joined.contains("code-server --server-data-dir") && joined.contains("--list-extensions") {
        return .extensionSync
    }
    return .other
}

func attachedShouldEmitCompactSummary(kind: AttachedExecKind) -> Bool {
    switch kind {
    case .interactive, .userEnvProbe, .watchInstalledExtensions, .watchMachineSettings, .extensionInstall, .extensionSync:
        return true
    default:
        return false
    }
}

func attachedLifecycleDiagnosticEvents(
    kind: AttachedExecKind,
    outcome: String,
    fields: [String: String]
) -> [(event: String, fields: [String: String])] {
    switch kind {
    case .extensionInstall:
        return [("extension_install_\(outcome)", fields)]
    case .watchInstalledExtensions, .watchMachineSettings:
        if outcome == "started" {
            if fields["cycle"] == "restarted" {
                var activationFields = fields
                activationFields["activation_source"] = kind.rawValue
                return [
                    ("extension_watch_restarted", fields),
                    ("extension_activation_observed", activationFields)
                ]
            }
            return [("extension_watch_started", fields)]
        }
        return [("extension_watch_\(outcome)", fields)]
    case .extensionSync:
        var activationFields = fields
        activationFields["activation_source"] = "extension_sync_exec"
        if outcome == "started" {
            return [
                ("extension_sync_started", fields),
                ("extension_activation_observed", activationFields)
            ]
        }
        return [("extension_sync_\(outcome)", fields)]
    default:
        return []
    }
}

private final class AttachedExecMetrics {
    private let lock = NSLock()
    private let startedAt = Date()
    private var firstOutputAt: Date?
    private var lastOutputAt: Date?
    private var exitAt: Date?
    private var bytesIn = 0
    private var bytesOut = 0

    func observeInput(bytes: Int) {
        lock.lock()
        bytesIn += bytes
        lock.unlock()
    }

    func observeOutput(bytes: Int) {
        let now = Date()
        lock.lock()
        bytesOut += bytes
        if firstOutputAt == nil {
            firstOutputAt = now
        }
        lastOutputAt = now
        lock.unlock()
    }

    func observeExit() {
        lock.lock()
        exitAt = Date()
        lock.unlock()
    }

    func summaryFields() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        let firstOutputLatencyMs = firstOutputAt.map { Int($0.timeIntervalSince(startedAt) * 1000) } ?? -1
        let runtimeMs = Int((exitAt ?? Date()).timeIntervalSince(startedAt) * 1000)
        return [
            "started_at_epoch_ms": String(Int64(startedAt.timeIntervalSince1970 * 1000)),
            "first_output_latency_ms": firstOutputLatencyMs >= 0 ? String(firstOutputLatencyMs) : "",
            "runtime_ms": String(runtimeMs),
            "bytes_in": String(bytesIn),
            "bytes_out": String(bytesOut)
        ]
    }
}

private final class AttachedExecLifecycleTracker {
    private let lock = NSLock()
    private var lastStartedAtByKind: [AttachedExecKind: Date] = [:]
    private var lastExtensionInstallSucceededAt: Date?

    func startFields(for kind: AttachedExecKind, now: Date = Date()) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }

        var fields: [String: String] = [:]
        if let previous = lastStartedAtByKind[kind] {
            let gapMs = Int(now.timeIntervalSince(previous) * 1000)
            fields["cycle"] = "restarted"
            fields["restart_gap_ms"] = String(gapMs)
        } else {
            fields["cycle"] = "started"
        }
        lastStartedAtByKind[kind] = now

        if kind == .extensionSync, let lastExtensionInstallSucceededAt {
            let gapMs = Int(now.timeIntervalSince(lastExtensionInstallSucceededAt) * 1000)
            fields["since_last_extension_install_ms"] = String(gapMs)
        }
        return fields
    }

    func completionFields(for kind: AttachedExecKind, succeeded: Bool, now: Date = Date()) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }

        if kind == .extensionInstall, succeeded {
            lastExtensionInstallSucceededAt = now
        }
        return [:]
    }
}

private struct AttachedRuntimeUser {
    var name: String
    var home: String
    var shell: String
}

private func attachedLogDiagnosticLifecycle(
    logger: MSLLogger,
    kind: AttachedExecKind,
    outcome: String,
    fields: [String: String]
) {
    for entry in attachedLifecycleDiagnosticEvents(kind: kind, outcome: outcome, fields: fields) {
        logger.log(entry.event, fields: entry.fields)
    }
}

private func attachedLogCompactSummary(
    logger: MSLLogger,
    kind: AttachedExecKind,
    fields: [String: String]
) {
    guard attachedShouldEmitCompactSummary(kind: kind) else {
        return
    }
    logger.log("attached_exec_compact_summary", fields: fields)
}

private func dockerExecEnvListToMap(_ envList: [String]?) -> [String: String] {
    guard let envList else { return [:] }
    var result: [String: String] = [:]
    for entry in envList {
        guard let equalsIndex = entry.firstIndex(of: "=") else { continue }
        let key = String(entry[..<equalsIndex])
        guard !key.isEmpty else { continue }
        let value = String(entry[entry.index(after: equalsIndex)...])
        result[key] = value
    }
    return result
}

enum AttachedContainerIdentity {
    static func vmID(forInstance instance: String) -> String {
        let lowered = instance.lowercased()
        let normalized = lowered.map { ch -> Character in
            let scalar = ch.unicodeScalars.first?.value ?? 0
            let isLowerAlpha = scalar >= 97 && scalar <= 122
            let isDigit = scalar >= 48 && scalar <= 57
            return (isLowerAlpha || isDigit || ch == "-" || ch == "_") ? ch : "-"
        }
        let joined = String(normalized)
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return "msl-\(joined.isEmpty ? "default" : joined)"
    }

    static func socketPath(forInstance instance: String) -> String {
        let hash = fnv1a64Hex(instance)
        let runtimeRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("msl", isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true)
        return runtimeRoot
            .appendingPathComponent("a-\(hash).sock", isDirectory: false)
            .path
    }

    static func containerID(forInstance instance: String) -> String {
        deterministicHex(seed: "container:\(instance)", length: 64)
    }

    static func imageID(forInstance instance: String) -> String {
        "sha256:\(deterministicHex(seed: "image:\(instance)", length: 64))"
    }

    static func imageDigest(forInstance instance: String) -> String {
        "sha256:\(deterministicHex(seed: "manifest:\(instance)", length: 64))"
    }

    static func networkID(forInstance instance: String) -> String {
        deterministicHex(seed: "network:\(instance)", length: 64)
    }

    static func sandboxID(forInstance instance: String) -> String {
        deterministicHex(seed: "sandbox:\(instance)", length: 64)
    }

    static func endpointID(forInstance instance: String) -> String {
        deterministicHex(seed: "endpoint:\(instance)", length: 64)
    }

    static func macAddress(forInstance instance: String) -> String {
        let hex = deterministicHex(seed: "mac:\(instance)", length: 10)
        let pairs = stride(from: 0, to: hex.count, by: 2).map { idx -> String in
            let start = hex.index(hex.startIndex, offsetBy: idx)
            let end = hex.index(start, offsetBy: 2)
            return String(hex[start..<end])
        }
        return (["02"] + pairs).joined(separator: ":")
    }

    private static func fnv1a64Hex(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for b in value.utf8 {
            hash ^= UInt64(b)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    private static func deterministicHex(seed: String, length: Int) -> String {
        var output = ""
        var counter = 0
        while output.count < length {
            output += fnv1a64Hex("\(seed):\(counter)")
            counter += 1
        }
        return String(output.prefix(length))
    }
}

private struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
}

private enum HTTPRequestReadResult {
    case success(HTTPRequest, remaining: Data)
    case closed(bytesRead: Int)
    case failure(reason: String, bytesRead: Int)
}

private enum HTTPRequestHandlingAction {
    case keepAlive
    case close
    case upgrade(AttachedExecSession)
}

private struct AttachedExecReadOutcome {
    var exitCode: Int32?
    var exitReason: String?
    var chunkCount: Int
    var stdoutBytes: Int
    var stderrBytes: Int
}

private struct AttachedExecOutputFrame {
    var stream: String
    var payload: Data
    var framed: Data
}

private struct CanonicalDockerRequestPath {
    var rawPath: String
    var pathWithoutQuery: String
    var canonicalPath: String
    var query: String?
    var apiVersion: String?
}

private final class AttachedExecRegistry {
    private var sessions: [String: AttachedExecSession] = [:]
    private let lock = NSLock()

    func put(_ session: AttachedExecSession) {
        lock.lock()
        sessions[session.execID] = session
        lock.unlock()
    }

    func get(_ execID: String) -> AttachedExecSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[execID]
    }

    func remove(_ execID: String) {
        lock.lock()
        sessions.removeValue(forKey: execID)
        lock.unlock()
    }

    func update(_ execID: String, transform: (inout AttachedExecSession) -> Void) {
        lock.lock()
        if var session = sessions[execID] {
            transform(&session)
            sessions[execID] = session
        }
        lock.unlock()
    }

    func execIDs(forContainerID containerID: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return sessions.values
            .filter { $0.containerID == containerID }
            .map(\.execID)
            .sorted()
    }
}

final class AttachedContainerDaemon {
    let socketPath: String
    private let paths: MSLPaths
    private let lock: FileLock
    private let store: StateStore
    private let logger: MSLLogger
    private let executablePath: String
    private let explicitInstanceName: String?
    private let distributionManager: DistributionManager

    private let execRegistry = AttachedExecRegistry()
    private let lifecycleTracker = AttachedExecLifecycleTracker()
    private var listenFD: Int32 = -1
    private var running = false
    private var acceptThread: Thread?

    init(
        paths: MSLPaths,
        lock: FileLock,
        store: StateStore,
        logger: MSLLogger,
        executablePath: String,
        explicitInstanceName: String?,
        distributionManager: DistributionManager
    ) {
        self.paths = paths
        self.lock = lock
        self.store = store
        self.logger = logger
        self.executablePath = executablePath
        self.explicitInstanceName = explicitInstanceName
        self.distributionManager = distributionManager
        let scopedInstance = explicitInstanceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let instanceForSocket: String
        if let scopedInstance, !scopedInstance.isEmpty {
            instanceForSocket = scopedInstance
        } else {
            instanceForSocket = "default"
        }
        self.socketPath = AttachedContainerIdentity.socketPath(forInstance: instanceForSocket)
    }

    func start() throws {
        if running {
            return
        }
        try startSocket()
        running = true
        logger.log("attached_daemon_started", fields: [
            "socket": socketPath,
            "instance_scope": explicitInstanceName ?? "all"
        ])

        let thread = Thread { [weak self] in
            self?.acceptLoop()
        }
        thread.name = "msl.attached.accept"
        thread.start()
        acceptThread = thread
    }

    func run() throws -> Never {
        try start()
        while running {
            Thread.sleep(forTimeInterval: 0.5)
        }
        Foundation.exit(0)
    }

    func stop() {
        guard running else { return }
        running = false
        if listenFD >= 0 {
            _ = shutdown(listenFD, SHUT_RDWR)
            _ = close(listenFD)
            listenFD = -1
        }
        if FileManager.default.fileExists(atPath: socketPath) {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        logger.log("attached_daemon_stopped", fields: ["socket": socketPath])
    }

    private func acceptLoop() {
        while running {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR {
                    continue
                }
                logger.log("attached_socket_accept_failed", fields: [
                    "socket": socketPath,
                    "error": lastErr()
                ])
                usleep(50_000)
                continue
            }
            let thread = Thread { [weak self] in
                self?.handleClient(fd: clientFD)
            }
            thread.name = "msl.attached.client"
            thread.start()
        }
    }

    private func startSocket() throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: socketPath) {
            try FileManager.default.removeItem(atPath: socketPath)
        }

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            throw MSLRuntimeError("attached_socket_bind_failed: \(lastErr())")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        if pathBytes.count >= MemoryLayout.size(ofValue: addr.sun_path) {
            throw MSLRuntimeError("attached socket path too long")
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
        guard bindResult == 0 else {
            throw MSLRuntimeError("attached_socket_bind_failed: \(lastErr())")
        }
        guard listen(listenFD, 32) == 0 else {
            throw MSLRuntimeError("attached_socket_bind_failed: \(lastErr())")
        }
        _ = chmod(socketPath, S_IRUSR | S_IWUSR)
    }

    private func handleClient(fd: Int32) {
        let connectionID = UUID().uuidString.lowercased()
        let peer = peerIdentity(fd: fd)
        var socketClosed = false
        func closeSocket(mode: Int32, modeLabel: String, reason: String) {
            guard !socketClosed else { return }
            logger.log("attached_socket_client_shutdown_started", fields: [
                "connection_id": connectionID,
                "mode": modeLabel,
                "reason": reason
            ])
            _ = shutdown(fd, mode)
            logger.log("attached_socket_client_shutdown_finished", fields: [
                "connection_id": connectionID,
                "mode": modeLabel,
                "reason": reason
            ])
            _ = close(fd)
            socketClosed = true
        }
        logger.log("attached_socket_client_accepted", fields: [
            "connection_id": connectionID,
            "socket": socketPath,
            "client_uid": peer.uid,
            "client_gid": peer.gid
        ])
        defer {
            logger.log("attached_socket_client_closed", fields: [
                "connection_id": connectionID
            ])
            closeSocket(mode: SHUT_RDWR, modeLabel: "full", reason: "client_handler_finished")
        }

        var pendingBytes = Data()
        while true {
            let readResult = readHTTPRequest(fd: fd, bufferedData: pendingBytes)
            switch readResult {
            case .closed:
                logger.log("attached_socket_client_eof", fields: [
                    "connection_id": connectionID,
                    "pending_bytes": String(pendingBytes.count)
                ])
                return
            case .failure(let reason, let bytesRead):
                logger.log("attached_socket_client_read_failed", fields: [
                    "connection_id": connectionID,
                    "reason": reason,
                    "bytes_read": String(bytesRead)
                ])
                return
            case .success(let request, let remaining):
                pendingBytes = remaining
                let normalizedPath = canonicalDockerPath(request.path)
                let path = normalizedPath.rawPath
                let canonicalPath = normalizedPath.canonicalPath
                let bodyPreview = requestBodyPreview(request.body)
                logger.log("attached_socket_client_request_parsed", fields: [
                    "connection_id": connectionID,
                    "method": request.method,
                    "path": path,
                    "canonical_path": canonicalPath,
                    "remaining_bytes": String(remaining.count),
                    "content_length": String(request.body.count)
                ])
                logger.log("attached_api_request", fields: [
                    "connection_id": connectionID,
                    "method": request.method,
                    "path": path,
                    "path_without_query": normalizedPath.pathWithoutQuery,
                    "canonical_path": canonicalPath,
                    "query": normalizedPath.query ?? "",
                    "api_version": normalizedPath.apiVersion ?? "",
                    "content_length": String(request.body.count),
                    "user_agent": request.headers["user-agent"] ?? "",
                    "body_preview": bodyPreview
                ])
                switch handleHTTPRequest(
                    fd: fd,
                    request: request,
                    connectionID: connectionID,
                    rawPath: path,
                    canonicalPath: canonicalPath
                ) {
                case .keepAlive:
                    continue
                case .close:
                    return
                case .upgrade(let session):
                    logger.log("attached_socket_client_upgrade_started", fields: [
                        "connection_id": connectionID,
                        "exec_id": session.execID,
                        "tty": session.tty ? "true" : "false",
                        "pending_bytes": String(pendingBytes.count)
                    ])
                    let closeDisposition = hijackExecConnection(
                        fd: fd,
                        session: session,
                        connectionID: connectionID,
                        initialClientBytes: pendingBytes
                    )
                    logger.log("attached_socket_client_upgrade_finished", fields: [
                        "connection_id": connectionID,
                        "exec_id": session.execID
                    ])
                    if closeDisposition == .closed {
                        socketClosed = true
                    }
                    return
                }
            }
        }
    }

    private func handleHTTPRequest(
        fd: Int32,
        request: HTTPRequest,
        connectionID: String,
        rawPath path: String,
        canonicalPath: String
    ) -> HTTPRequestHandlingAction {
        if (request.method == "GET" || request.method == "HEAD"),
           canonicalPath == "/_ping" {
            logger.log("attached_api_response", fields: [
                "connection_id": connectionID,
                "method": request.method,
                "path": path,
                "canonical_path": canonicalPath,
                "status": "200"
            ])
            writeHTTPResponse(
                fd: fd,
                status: 200,
                contentType: "text/plain",
                body: Data("OK".utf8),
                includeBody: request.method != "HEAD"
            )
            return .keepAlive
        }

        if request.method == "GET", canonicalPath == "/version" {
            logger.log("attached_api_response", fields: [
                "connection_id": connectionID,
                "method": request.method,
                "path": path,
                "canonical_path": canonicalPath,
                "status": "200"
            ])
            writeJSONResponse(fd: fd, status: 200, body: [
                "ApiVersion": attachedDockerAPIVersion,
                "Version": "msl-attached-1",
                "MinAPIVersion": attachedDockerMinAPIVersion,
                "Os": "linux",
                "Arch": "arm64"
            ])
            return .keepAlive
        }

        if request.method == "GET", canonicalPath == "/containers/json" {
            logger.log("attached_api_response", fields: [
                "connection_id": connectionID,
                "method": request.method,
                "path": path,
                "canonical_path": canonicalPath,
                "status": "200"
            ])
            let containers = resolveContainers().map { $0.containerSummaryJSON() }
            writeJSONArray(fd: fd, status: 200, body: containers)
            return .keepAlive
        }

        if request.method == "GET",
           let id = match(path: canonicalPath, pattern: #"^/containers/([^/]+)/json$"#) {
            guard let container = resolveContainer(identifier: id) else {
                logger.log("attached_api_response", fields: [
                    "connection_id": connectionID,
                    "method": request.method,
                    "path": path,
                    "canonical_path": canonicalPath,
                    "status": "404",
                    "reason": "container_not_found"
                ])
                writeJSONResponse(fd: fd, status: 404, body: ["message": "container_not_found"])
                return .keepAlive
            }
            logger.log("attached_api_response", fields: [
                "connection_id": connectionID,
                "method": request.method,
                "path": path,
                "canonical_path": canonicalPath,
                "status": "200"
            ])
            writeJSONResponse(
                fd: fd,
                status: 200,
                body: container.inspectJSON(execIDs: execRegistry.execIDs(forContainerID: container.containerID))
            )
            return .keepAlive
        }

        if request.method == "POST",
           let id = match(path: canonicalPath, pattern: #"^/containers/([^/]+)/exec$"#) {
            guard let container = resolveContainer(identifier: id) else {
                logger.log("attached_api_response", fields: [
                    "connection_id": connectionID,
                    "method": request.method,
                    "path": path,
                    "canonical_path": canonicalPath,
                    "status": "404",
                    "reason": "container_not_found"
                ])
                writeJSONResponse(fd: fd, status: 404, body: ["message": "container_not_found"])
                logger.log("attached_exec_create_failed", fields: [
                    "connection_id": connectionID,
                    "reason": "container_not_found",
                    "vm_id": id
                ])
                return .keepAlive
            }
            guard let payload = try? JSONDecoder().decode(AttachedExecCreateRequest.self, from: request.body) else {
                logger.log("attached_api_response", fields: [
                    "connection_id": connectionID,
                    "method": request.method,
                    "path": path,
                    "canonical_path": canonicalPath,
                    "status": "400",
                    "reason": "invalid_exec_request"
                ])
                writeJSONResponse(fd: fd, status: 400, body: ["message": "invalid_exec_request"])
                logger.log("attached_exec_create_failed", fields: [
                    "connection_id": connectionID,
                    "reason": "invalid_exec_request",
                    "vm_id": id
                ])
                return .keepAlive
            }
            if let validationError = attachedValidateExecCreateRequest(cmd: payload.Cmd) {
                logger.log("attached_api_response", fields: [
                    "connection_id": connectionID,
                    "method": request.method,
                    "path": path,
                    "canonical_path": canonicalPath,
                    "status": "400",
                    "reason": validationError
                ])
                writeJSONResponse(fd: fd, status: 400, body: ["message": validationError])
                logger.log("attached_exec_create_failed", fields: [
                    "connection_id": connectionID,
                    "reason": validationError,
                    "vm_id": id
                ])
                return .keepAlive
            }
            let execID = randomHex(length: 64)
            let session = AttachedExecSession(
                execID: execID,
                instance: container.instance,
                vmID: container.vmID,
                containerID: container.containerID,
                cmd: payload.Cmd ?? ["/bin/sh"],
                workingDir: payload.WorkingDir?.nilIfEmpty ?? container.defaultHome,
                tty: payload.Tty ?? true,
                attachStdin: payload.AttachStdin ?? true,
                attachStdout: payload.AttachStdout ?? true,
                attachStderr: payload.AttachStderr ?? true,
                detachKeys: payload.DetachKeys ?? "",
                user: payload.User?.nilIfEmpty ?? container.defaultUser,
                envAdditions: dockerExecEnvListToMap(payload.Env),
                privileged: payload.Privileged ?? false,
                running: false,
                exitCode: nil,
                pid: nil,
                createdAtEpochMs: nowEpochMs()
            )
            execRegistry.put(session)
            let execKind = attachedExecKind(session: session)
            logger.log("attached_api_response", fields: [
                "connection_id": connectionID,
                "method": request.method,
                "path": path,
                "canonical_path": canonicalPath,
                "status": "201"
            ])
            writeJSONResponse(fd: fd, status: 201, body: ["Id": execID])
            logger.log("attached_exec_started", fields: [
                "connection_id": connectionID,
                "phase": "create",
                "exec_id": execID,
                "vm_id": container.vmID,
                "instance": container.instance,
                "tty": session.tty ? "true" : "false",
                "cmd": session.cmd.joined(separator: " "),
                "exec_kind": execKind.rawValue
            ])
            return .close
        }

        if request.method == "GET",
           let execID = match(path: canonicalPath, pattern: #"^/exec/([^/]+)/json$"#) {
            guard let session = execRegistry.get(execID) else {
                logger.log("attached_api_response", fields: [
                    "connection_id": connectionID,
                    "method": request.method,
                    "path": path,
                    "canonical_path": canonicalPath,
                    "status": "404",
                    "reason": "exec_not_found"
                ])
                writeJSONResponse(fd: fd, status: 404, body: ["message": "exec_not_found"])
                return .keepAlive
            }
            logger.log("attached_api_response", fields: [
                "connection_id": connectionID,
                "method": request.method,
                "path": path,
                "canonical_path": canonicalPath,
                "status": "200"
            ])
            writeJSONResponse(fd: fd, status: 200, body: session.inspectJSON())
            return .keepAlive
        }

        if request.method == "POST",
           let execID = match(path: canonicalPath, pattern: #"^/exec/([^/]+)/start$"#) {
            return handleExecStartRequest(
                fd: fd,
                execID: execID,
                request: request,
                connectionID: connectionID,
                rawPath: path,
                canonicalPath: canonicalPath
            )
        }

        logger.log("attached_api_response", fields: [
            "connection_id": connectionID,
            "method": request.method,
            "path": path,
            "canonical_path": canonicalPath,
            "status": "404",
            "reason": "docker_api_unsupported_endpoint"
        ])
        writeJSONResponse(fd: fd, status: 404, body: ["message": "docker_api_unsupported_endpoint"])
        logger.log("attached_api_rejected", fields: [
            "connection_id": connectionID,
            "reason": "docker_api_unsupported_endpoint",
            "method": request.method,
            "path": path,
            "canonical_path": canonicalPath
        ])
        return .keepAlive
    }

    private func resolveContainers() -> [AttachedContainerDescriptor] {
        let names: [String]
        if let explicit = explicitInstanceName, !explicit.isEmpty {
            names = [explicit]
        } else {
            names = distributionManager.installedInstances()
                .filter { $0.hasDisk && !distributionManager.isReservedInternalInstanceName($0.name) }
                .map { $0.name }
        }

        return names.map { name in
            let vmID = AttachedContainerIdentity.vmID(forInstance: name)
            let runtimeUser = resolveRuntimeUser(forInstance: name)
            return AttachedContainerDescriptor(
                instance: name,
                vmID: vmID,
                name: vmID,
                image: "msl/\(name)",
                running: true,
                platform: "linux",
                defaultUser: runtimeUser.name,
                defaultHome: runtimeUser.home,
                defaultShell: runtimeUser.shell
            )
        }
    }

    private func resolveRuntimeUser(forInstance instance: String) -> AttachedRuntimeUser {
        let fallbackUser = ProcessInfo.processInfo.environment["USER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? NSUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        let safeFallbackUser = fallbackUser.isEmpty ? "root" : fallbackUser
        let fallback = AttachedRuntimeUser(
            name: safeFallbackUser,
            home: safeFallbackUser == "root" ? "/root" : "/home/\(safeFallbackUser)",
            shell: "/bin/sh"
        )

        do {
            return try lock.withExclusiveLock(timeoutSec: 1) {
                let state = try store.loadState()
                guard let runtimeUser = state.instances?.first(where: { $0.instance == instance })?.runtimeUser else {
                    return fallback
                }
                return AttachedRuntimeUser(
                    name: runtimeUser.name,
                    home: runtimeUser.home,
                    shell: runtimeUser.shell
                )
            }
        } catch {
            return fallback
        }
    }

    private func resolveContainer(identifier: String) -> AttachedContainerDescriptor? {
        let normalized = identifier.hasPrefix("/") ? String(identifier.dropFirst()) : identifier
        return resolveContainers().first {
            $0.vmID == normalized ||
            $0.name == normalized ||
            $0.containerID == normalized ||
            $0.containerID.hasPrefix(normalized)
        }
    }

    private func canonicalDockerPath(_ raw: String) -> CanonicalDockerRequestPath {
        let parts = raw.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let withoutQuery = parts.first.map(String.init) ?? raw
        let query = parts.count > 1 ? String(parts[1]) : nil
        let versionMatch = match(path: withoutQuery, pattern: #"^/v([0-9]+(?:\.[0-9]+)?)(?:/.*)?$"#)
        let canonicalPath: String
        if let stripped = match(path: withoutQuery, pattern: #"^/v[0-9]+(?:\.[0-9]+)?(/.*)$"#) {
            canonicalPath = stripped.isEmpty ? "/" : stripped
        } else {
            canonicalPath = withoutQuery
        }
        return CanonicalDockerRequestPath(
            rawPath: raw,
            pathWithoutQuery: withoutQuery,
            canonicalPath: canonicalPath,
            query: query,
            apiVersion: versionMatch
        )
    }

    private func requestBodyPreview(_ body: Data) -> String {
        guard !body.isEmpty else { return "" }
        let prefix = body.prefix(512)
        let text = String(data: prefix, encoding: .utf8) ?? "<non-utf8>"
        if body.count > prefix.count {
            return text + "..."
        }
        return text
    }

    private func handleExecStartRequest(
        fd: Int32,
        execID: String,
        request: HTTPRequest,
        connectionID: String,
        rawPath path: String,
        canonicalPath: String
    ) -> HTTPRequestHandlingAction {
        guard var session = execRegistry.get(execID) else {
            logger.log("attached_api_response", fields: [
                "connection_id": connectionID,
                "method": request.method,
                "path": path,
                "canonical_path": canonicalPath,
                "status": "404",
                "reason": "exec_not_found"
            ])
            writeJSONResponse(fd: fd, status: 404, body: ["message": "exec_not_found"])
            logger.log("attached_exec_failed", fields: [
                "connection_id": connectionID,
                "reason": "exec_not_found",
                "exec_id": execID
            ])
            return .keepAlive
        }

        let startPayload: AttachedExecStartRequest
        if request.body.isEmpty {
            startPayload = AttachedExecStartRequest(Detach: nil, Tty: nil)
        } else if let decoded = try? JSONDecoder().decode(AttachedExecStartRequest.self, from: request.body) {
            startPayload = decoded
        } else {
            logger.log("attached_api_response", fields: [
                "connection_id": connectionID,
                "method": request.method,
                "path": path,
                "canonical_path": canonicalPath,
                "status": "400",
                "reason": "invalid_exec_start_request"
            ])
            writeJSONResponse(fd: fd, status: 400, body: ["message": "invalid_exec_start_request"])
            logger.log("attached_exec_failed", fields: [
                "connection_id": connectionID,
                "reason": "invalid_exec_start_request",
                "exec_id": execID,
                "body_preview": requestBodyPreview(request.body)
            ])
            return .keepAlive
        }

        if let validationError = attachedValidateExecStartRequest(
            detach: startPayload.Detach,
            requestedTTY: startPayload.Tty,
            sessionTTY: session.tty
        ) {
            logger.log("attached_api_response", fields: [
                "connection_id": connectionID,
                "method": request.method,
                "path": path,
                "canonical_path": canonicalPath,
                "status": "400",
                "reason": validationError
            ])
            writeJSONResponse(fd: fd, status: 400, body: ["message": validationError])
            var fields: [String: String] = [
                "connection_id": connectionID,
                "reason": validationError,
                "exec_id": execID
            ]
            if let requestedTTY = startPayload.Tty {
                fields["session_tty"] = session.tty ? "true" : "false"
                fields["request_tty"] = requestedTTY ? "true" : "false"
            }
            logger.log("attached_exec_failed", fields: fields)
            return .keepAlive
        }

        session.running = false
        session.exitCode = nil
        session.pid = nil
        execRegistry.put(session)
        let execKind = attachedExecKind(session: session)
        var startFields: [String: String] = [
            "connection_id": connectionID,
            "phase": "start",
            "exec_id": execID,
            "vm_id": session.vmID,
            "instance": session.instance,
            "tty": session.tty ? "true" : "false",
            "detach": startPayload.Detach == true ? "true" : "false",
            "exec_kind": execKind.rawValue
        ]
        startFields.merge(lifecycleTracker.startFields(for: execKind)) { _, new in new }

        logger.log("attached_exec_started", fields: startFields)
        attachedLogDiagnosticLifecycle(logger: logger, kind: execKind, outcome: "started", fields: startFields)
        logger.log("attached_api_response", fields: [
            "connection_id": connectionID,
            "method": request.method,
            "path": path,
            "canonical_path": canonicalPath,
            "status": "101"
        ])
        _ = writeExecStartUpgradeResponse(fd: fd, tty: session.tty)
        return .upgrade(session)
    }

    @discardableResult
    private func writeExecStartUpgradeResponse(fd: Int32, tty: Bool) -> Bool {
        writeRaw(
            fd,
            "HTTP/1.1 101 UPGRADED\r\n" +
            "Api-Version: \(attachedDockerAPIVersion)\r\n" +
            "Connection: Upgrade\r\n" +
            "Content-Type: \(attachedExecStartContentType(tty: tty))\r\n" +
            "Docker-Experimental: false\r\n" +
            "Ostype: linux\r\n" +
            "Server: \(attachedDockerServerHeader)\r\n" +
            "Upgrade: tcp\r\n" +
            "\r\n"
        )
    }

    @discardableResult
    private func hijackExecConnection(
        fd: Int32,
        session: AttachedExecSession,
        connectionID: String,
        initialClientBytes: Data = Data()
    ) -> AttachedExecConnectionCloseDisposition {
        runExecBridge(
            fd: fd,
            session: session,
            connectionID: connectionID,
            initialClientBytes: initialClientBytes
        )
    }

    private func runExecBridge(
        fd: Int32,
        session: AttachedExecSession,
        connectionID: String,
        initialClientBytes: Data = Data()
    ) -> AttachedExecConnectionCloseDisposition {
        if session.tty {
            runTTYExecBridge(
                fd: fd,
                session: session,
                connectionID: connectionID,
                initialClientBytes: initialClientBytes
            )
        } else {
            runNonTTYExecBridge(
                fd: fd,
                session: session,
                connectionID: connectionID,
                initialClientBytes: initialClientBytes
            )
        }
        let mode = attachedExecConnectionMode(session: session)
        logger.log("attached_exec_close_started", fields: [
            "connection_id": connectionID,
            "exec_id": session.execID,
            "mode": mode.logValue
        ])
        logger.log("attached_socket_client_shutdown_started", fields: [
            "connection_id": connectionID,
            "mode": "write",
            "reason": "exec_bridge_finished",
            "exec_id": session.execID
        ])
        _ = shutdown(fd, SHUT_WR)
        logger.log("attached_socket_client_shutdown_finished", fields: [
            "connection_id": connectionID,
            "mode": "write",
            "reason": "exec_bridge_finished",
            "exec_id": session.execID
        ])
        if mode == .finiteOneShot {
            logger.log("attached_socket_client_shutdown_started", fields: [
                "connection_id": connectionID,
                "mode": "full",
                "reason": "finite_exec_finished",
                "exec_id": session.execID
            ])
            _ = shutdown(fd, SHUT_RDWR)
            logger.log("attached_socket_client_shutdown_finished", fields: [
                "connection_id": connectionID,
                "mode": "full",
                "reason": "finite_exec_finished",
                "exec_id": session.execID
            ])
            _ = close(fd)
            logger.log("attached_exec_close_finished", fields: [
                "connection_id": connectionID,
                "exec_id": session.execID,
                "mode": mode.logValue,
                "close": "full"
            ])
            return .closed
        }
        logger.log("attached_exec_close_finished", fields: [
            "connection_id": connectionID,
            "exec_id": session.execID,
            "mode": mode.logValue,
            "close": "write"
        ])
        return .deferred
    }

    private func runTTYExecBridge(
        fd: Int32,
        session: AttachedExecSession,
        connectionID: String,
        initialClientBytes: Data
    ) {
        let execKind = attachedExecKind(session: session)
        let metrics = AttachedExecMetrics()
        let daemonClient = DaemonClient(
            paths: paths,
            lock: lock,
            store: store,
            logger: logger,
            executablePath: executablePath
        )

        do {
            try daemonClient.ensureConnected(expectedInstanceName: session.instance)
            let reg = try daemonClient.send(RuntimeControlRequest(
                op: "session_register",
                instance: session.instance
            ))
            guard reg.ok, let sessionID = reg.sessionId else {
                throw MSLRuntimeError(reg.error ?? "failed to register attached session")
            }
            defer {
                _ = try? daemonClient.send(RuntimeControlRequest(op: "session_unregister", sessionId: sessionID))
                daemonClient.disconnect()
            }

            let ptyOpen = try daemonClient.send(RuntimeControlRequest(
                op: "pty_open",
                argv: session.cmd,
                runAsRoot: session.user == "root",
                rows: 40,
                cols: 120,
                sessionId: sessionID,
                cwd: session.workingDir,
                envAdditions: session.envAdditions.isEmpty ? nil : session.envAdditions
            ))
            guard ptyOpen.ok, let ptyID = ptyOpen.ptyId else {
                throw MSLRuntimeError(ptyOpen.error ?? "failed to open attached pty")
            }
            execRegistry.update(session.execID) {
                $0.running = true
                $0.pid = attachedExecPID(from: session.execID)
            }
            defer {
                schedulePtyClose(instance: session.instance, ptyID: ptyID, sessionID: sessionID)
            }

            let result = try SessionStreamBridge.runPty(
                daemonClient: daemonClient,
                ptyID: ptyID,
                sessionID: sessionID,
                inputFD: attachedShouldPumpInput(attachStdin: session.attachStdin) ? fd : nil,
                initialInput: initialClientBytes,
                onInputChunk: { chunk in
                    metrics.observeInput(bytes: chunk.count)
                },
                onOutput: { [self] data in
                    metrics.observeOutput(bytes: data.count)
                    guard attachedShouldForwardStream(
                        tty: session.tty,
                        attachStdout: session.attachStdout,
                        attachStderr: session.attachStderr,
                        stream: "stdout"
                    ) else {
                        return true
                    }
                    return self.writeData(fd, data: data)
                }
            )
            metrics.observeExit()
            execRegistry.update(session.execID) {
                $0.running = false
                $0.exitCode = Int(result.exitCode)
                $0.pid = nil
            }
            logger.log("attached_exec_finished", fields: [
                "connection_id": connectionID,
                "exec_id": session.execID,
                "instance": session.instance,
                "vm_id": session.vmID,
                "result": "exit",
                "exec_kind": execKind.rawValue,
                "exit_code": String(result.exitCode),
                "exit_reason": result.exitReason ?? "unknown"
            ].merging(metrics.summaryFields()) { _, new in new })
            var successFields: [String: String] = [
                "connection_id": connectionID,
                "exec_id": session.execID,
                "instance": session.instance,
                "vm_id": session.vmID,
                "result": "exit",
                "exec_kind": execKind.rawValue,
                "exit_code": String(result.exitCode),
                "exit_reason": result.exitReason ?? "unknown"
            ]
            successFields.merge(metrics.summaryFields()) { _, new in new }
            successFields.merge(lifecycleTracker.completionFields(for: execKind, succeeded: true)) { _, new in new }
            attachedLogDiagnosticLifecycle(logger: logger, kind: execKind, outcome: "succeeded", fields: successFields)
            attachedLogCompactSummary(logger: logger, kind: execKind, fields: successFields)
        } catch {
            metrics.observeExit()
            execRegistry.update(session.execID) {
                $0.running = false
                $0.exitCode = 126
                $0.pid = nil
            }
            let reason = classifyBridgeFailureReason(error)
            logger.log("attached_exec_failed", fields: [
                "connection_id": connectionID,
                "exec_id": session.execID,
                "instance": session.instance,
                "vm_id": session.vmID,
                "exec_kind": execKind.rawValue,
                "reason": reason,
                "error": String(describing: error)
            ].merging(metrics.summaryFields()) { _, new in new })
            var failureFields: [String: String] = [
                "connection_id": connectionID,
                "exec_id": session.execID,
                "instance": session.instance,
                "vm_id": session.vmID,
                "exec_kind": execKind.rawValue,
                "reason": reason,
                "error": String(describing: error)
            ]
            failureFields.merge(metrics.summaryFields()) { _, new in new }
            failureFields.merge(lifecycleTracker.completionFields(for: execKind, succeeded: false)) { _, new in new }
            attachedLogDiagnosticLifecycle(logger: logger, kind: execKind, outcome: "failed", fields: failureFields)
            attachedLogCompactSummary(logger: logger, kind: execKind, fields: failureFields)
            if attachedShouldForwardStream(
                tty: session.tty,
                attachStdout: session.attachStdout,
                attachStderr: session.attachStderr,
                stream: "stderr"
            ) {
                let payload = Data("attached exec error: \(error)\n".utf8)
                let outgoing = session.tty ? payload : dockerMuxFrame(streamID: 2, payload: payload)
                _ = writeData(fd, data: outgoing)
            }
        }
    }

    private func runNonTTYExecBridge(
        fd: Int32,
        session: AttachedExecSession,
        connectionID: String,
        initialClientBytes: Data
    ) {
        let execKind = attachedExecKind(session: session)
        let metrics = AttachedExecMetrics()
        let daemonClient = DaemonClient(
            paths: paths,
            lock: lock,
            store: store,
            logger: logger,
            executablePath: executablePath
        )
        let writerDaemonClient = DaemonClient(
            paths: paths,
            lock: lock,
            store: store,
            logger: logger,
            executablePath: executablePath
        )

        do {
            try daemonClient.ensureConnected(expectedInstanceName: session.instance)
            try writerDaemonClient.ensureConnected(expectedInstanceName: session.instance)
            let reg = try daemonClient.send(RuntimeControlRequest(
                op: "session_register",
                instance: session.instance
            ))
            guard reg.ok, let sessionID = reg.sessionId else {
                throw MSLRuntimeError(reg.error ?? "failed to register attached session")
            }
            defer {
                _ = try? daemonClient.send(RuntimeControlRequest(op: "session_unregister", sessionId: sessionID))
                daemonClient.disconnect()
                writerDaemonClient.disconnect()
            }

            let procOpen = try daemonClient.send(RuntimeControlRequest(
                op: "proc_open",
                argv: session.cmd,
                runAsRoot: session.user == "root",
                sessionId: sessionID,
                cwd: session.workingDir,
                envAdditions: session.envAdditions.isEmpty ? nil : session.envAdditions
            ))
            guard procOpen.ok, let procID = procOpen.procId else {
                throw MSLRuntimeError(procOpen.error ?? "failed to open attached process")
            }
            execRegistry.update(session.execID) {
                $0.running = true
                $0.pid = attachedExecPID(from: session.execID)
            }
            logger.log("attached_proc_opened", fields: [
                "connection_id": connectionID,
                "exec_id": session.execID,
                "proc_id": procID,
                "instance": session.instance,
                "vm_id": session.vmID,
                "cmd": session.cmd.joined(separator: " ")
            ])
            let shellSentinelTracker = attachedMakeShellSentinelTracker(
                session: session,
                connectionID: connectionID,
                procID: procID
            )
            let immediateMuxWriter = attachedMakeImmediateMuxWriter(session: session)
            defer {
                scheduleProcClose(instance: session.instance, procID: procID, sessionID: sessionID)
            }

            let completion = try SessionStreamBridge.runProc(
                daemonClient: writerDaemonClient,
                procID: procID,
                sessionID: sessionID,
                inputFD: attachedShouldPumpInput(attachStdin: session.attachStdin) ? fd : nil,
                attachInput: attachedShouldPumpInput(attachStdin: session.attachStdin),
                initialInput: initialClientBytes,
                onInputChunk: { [logger] chunk in
                    metrics.observeInput(bytes: chunk.count)
                    shellSentinelTracker?.consume(stream: .stdin, data: chunk)
                    if chunk.count <= 4096 {
                        logger.log("attached_proc_stdin", fields: [
                            "connection_id": connectionID,
                            "proc_id": procID,
                            "session_id": sessionID,
                            "exec_kind": execKind.rawValue,
                            "bytes": String(chunk.count),
                            "preview": previewBytes(chunk)
                        ])
                    } else {
                        logger.log("attached_proc_stdin", fields: [
                            "connection_id": connectionID,
                            "proc_id": procID,
                            "session_id": sessionID,
                            "exec_kind": execKind.rawValue,
                            "bytes": String(chunk.count),
                            "preview": "<binary>"
                        ])
                    }
                    logger.log("attached_exec_mux_client_bytes", fields: [
                        "connection_id": connectionID,
                        "proc_id": procID,
                        "session_id": sessionID,
                        "exec_kind": execKind.rawValue,
                        "direction": "client",
                        "bytes": String(chunk.count),
                        "preview": previewBytes(chunk),
                        "preview_hex": previewHexBytes(chunk),
                        "is_likely_text": isLikelyTextBytes(chunk) ? "true" : "false"
                    ])
                },
                onInputClosed: { [logger] reason, errnoValue in
                    var fields: [String: String] = [
                        "proc_id": procID,
                        "session_id": sessionID,
                        "exec_kind": execKind.rawValue,
                        "reason": reason
                    ]
                    if let errnoValue {
                        fields["errno"] = String(errnoValue)
                    }
                    logger.log("attached_proc_stdin_closed", fields: fields)
                },
                onOutput: { event in
                    metrics.observeOutput(bytes: event.data.count)
                    switch event.kind {
                    case .stdout:
                        shellSentinelTracker?.consume(stream: .stdout, data: event.data)
                    case .stderr:
                        shellSentinelTracker?.consume(stream: .stderr, data: event.data)
                    }
                    return self.forwardImmediateNonTTYChunk(
                        fd: fd,
                        event: event,
                        session: session,
                        connectionID: connectionID,
                        procID: procID,
                        immediateMuxWriter: immediateMuxWriter
                    )
                }
            )
            metrics.observeExit()
            if let immediateMuxWriter, !immediateMuxWriter.flushPending(fd: fd) {
                throw MSLRuntimeError("socket_write_failed")
            }
            logger.log("attached_exec_bridge_output_drained", fields: [
                "connection_id": connectionID,
                "exec_id": session.execID,
                "proc_id": procID,
                "tty": "false",
                "exec_kind": execKind.rawValue
            ])
            execRegistry.update(session.execID) {
                $0.running = false
                $0.exitCode = Int(completion.exitCode)
                $0.pid = nil
            }
            var fields: [String: String] = [
                "connection_id": connectionID,
                "exec_id": session.execID,
                "instance": session.instance,
                "vm_id": session.vmID,
                "result": "exit",
                "exec_kind": execKind.rawValue
            ]
            fields["exit_code"] = String(completion.exitCode)
            if let exitReason = completion.exitReason {
                fields["exit_reason"] = exitReason
            }
            fields.merge(metrics.summaryFields()) { _, new in new }
            fields.merge(lifecycleTracker.completionFields(for: execKind, succeeded: true)) { _, new in new }
            logger.log("attached_exec_finished", fields: fields)
            attachedLogDiagnosticLifecycle(logger: logger, kind: execKind, outcome: "succeeded", fields: fields)
            attachedLogCompactSummary(logger: logger, kind: execKind, fields: fields)
        } catch {
            metrics.observeExit()
            execRegistry.update(session.execID) {
                $0.running = false
                $0.exitCode = 126
                $0.pid = nil
            }
            let reason = classifyBridgeFailureReason(error)
            logger.log("attached_exec_failed", fields: [
                "connection_id": connectionID,
                "exec_id": session.execID,
                "instance": session.instance,
                "vm_id": session.vmID,
                "exec_kind": execKind.rawValue,
                "reason": reason,
                "error": String(describing: error)
            ].merging(metrics.summaryFields()) { _, new in new })
            var failureFields: [String: String] = [
                "connection_id": connectionID,
                "exec_id": session.execID,
                "instance": session.instance,
                "vm_id": session.vmID,
                "exec_kind": execKind.rawValue,
                "reason": reason,
                "error": String(describing: error)
            ]
            failureFields.merge(metrics.summaryFields()) { _, new in new }
            failureFields.merge(lifecycleTracker.completionFields(for: execKind, succeeded: false)) { _, new in new }
            attachedLogDiagnosticLifecycle(logger: logger, kind: execKind, outcome: "failed", fields: failureFields)
            attachedLogCompactSummary(logger: logger, kind: execKind, fields: failureFields)
            if attachedShouldForwardStream(
                tty: session.tty,
                attachStdout: session.attachStdout,
                attachStderr: session.attachStderr,
                stream: "stderr"
            ) {
                let payload = Data("attached exec error: \(error)\n".utf8)
                _ = writeData(fd, data: dockerMuxFrame(streamID: 2, payload: payload))
            }
        }
    }

    private func attachedMakeShellSentinelTracker(
        session: AttachedExecSession,
        connectionID: String,
        procID: String
    ) -> ShellServerSentinelTracker? {
        guard !session.tty, session.cmd.first == "/bin/sh" else {
            return nil
        }
        return ShellServerSentinelTracker(
            logger: logger,
            connectionID: connectionID,
            execID: session.execID,
            procID: procID
        )
    }

    private func attachedMakeImmediateMuxWriter(
        session: AttachedExecSession
    ) -> AttachedImmediateMuxWriter? {
        guard !session.tty, session.cmd.first == "/bin/sh" else {
            return nil
        }
        return AttachedImmediateMuxWriter()
    }

    private func runNonTTYExecOutputLoop(
        daemonClient: DaemonClient,
        session: AttachedExecSession,
        procID: String,
        sessionID: String,
        connectionID: String,
        state: BridgeState,
        outputQueue: AttachedExecOutputQueue
    ) throws -> AttachedExecReadOutcome {
        var chunkCount = 0
        var stdoutBytes = 0
        var stderrBytes = 0

        while !state.isClosed {
            let procReadTimeoutMs = state.isBulkTransferActive ? 300_000 : 200
            let response: RuntimeControlResponse
            do {
                logger.log("attached_exec_proc_read_request", fields: [
                    "connection_id": connectionID,
                    "exec_id": session.execID,
                    "proc_id": procID,
                    "timeout_ms": String(procReadTimeoutMs)
                ])
                response = try daemonClient.send(RuntimeControlRequest(
                    op: "proc_read",
                    timeoutMs: procReadTimeoutMs,
                    procId: procID,
                    sessionId: sessionID
                ))
            } catch {
                if isNonFatalProcReadTimeout(error) {
                    continue
                }
                throw error
            }
            if !response.ok {
                throw MSLRuntimeError(response.error ?? "attached proc_read failed")
            }

            let outcome = logNonTTYProcReadResponse(
                response,
                connectionID: connectionID,
                execID: session.execID,
                procID: procID
            )
            if outcome.chunkCount > 0 || outcome.stdoutBytes > 0 || outcome.stderrBytes > 0 {
                state.clearBulkTransfer()
            }
            chunkCount += outcome.chunkCount
            stdoutBytes += outcome.stdoutBytes
            stderrBytes += outcome.stderrBytes

            let wroteOutput = forwardNonTTYProcReadResponse(
                response,
                session: session,
                connectionID: connectionID,
                procID: procID,
                state: state,
                outputQueue: outputQueue
            )
            if wroteOutput {
                state.clearBulkTransfer()
            }
            if state.isClosed {
                break
            }
            if response.exitCode != nil {
                return AttachedExecReadOutcome(
                    exitCode: response.exitCode,
                    exitReason: response.meta?["exitReason"],
                    chunkCount: chunkCount,
                    stdoutBytes: stdoutBytes,
                    stderrBytes: stderrBytes
                )
            }
        }

        throw MSLRuntimeError("attached exec bridge closed before process exit")
    }

    private func logNonTTYProcReadResponse(
        _ response: RuntimeControlResponse,
        connectionID: String,
        execID: String,
        procID: String
    ) -> AttachedExecReadOutcome {
        let chunkCount = response.chunks?.count ?? 0
        let stdoutBytes = response.chunks?
            .filter { $0.stream == "stdout" }
            .reduce(0) { $0 + (($1.rawData ?? Data(base64Encoded: $1.dataBase64) ?? Data()).count) }
            ?? (response.rawStdout ?? response.stdoutBase64.flatMap { Data(base64Encoded: $0) } ?? Data()).count
        let stderrBytes = response.chunks?
            .filter { $0.stream == "stderr" }
            .reduce(0) { $0 + (($1.rawData ?? Data(base64Encoded: $1.dataBase64) ?? Data()).count) }
            ?? (response.rawStderr ?? response.stderrBase64.flatMap { Data(base64Encoded: $0) } ?? Data()).count

        logger.log("attached_exec_proc_read", fields: [
            "connection_id": connectionID,
            "exec_id": execID,
            "proc_id": procID,
            "chunk_count": String(chunkCount),
            "stdout_bytes": String(stdoutBytes),
            "stderr_bytes": String(stderrBytes),
            "exit_code": response.exitCode.map(String.init) ?? "",
            "exit_reason": response.meta?["exitReason"] ?? ""
        ])

        return AttachedExecReadOutcome(
            exitCode: response.exitCode,
            exitReason: response.meta?["exitReason"],
            chunkCount: chunkCount,
            stdoutBytes: stdoutBytes,
            stderrBytes: stderrBytes
        )
    }

    private func forwardNonTTYProcReadResponse(
        _ response: RuntimeControlResponse,
        session: AttachedExecSession,
        connectionID: String,
        procID: String,
        state: BridgeState,
        outputQueue: AttachedExecOutputQueue
    ) -> Bool {
        var wroteOutput = false
        let hasOrderedChunks = response.chunks?.isEmpty == false

        if let chunks = response.chunks, !chunks.isEmpty {
            for chunk in chunks {
                let data = chunk.rawData ?? Data(base64Encoded: chunk.dataBase64) ?? Data()
                guard !data.isEmpty else { continue }
                if forwardNonTTYChunk(
                    event: ProcOutputEvent(
                        kind: chunk.stream == "stderr" ? .stderr : .stdout,
                        data: data
                    ),
                    session: session,
                    connectionID: connectionID,
                    procID: procID,
                    state: state,
                    outputQueue: outputQueue
                ) {
                    wroteOutput = true
                }
                if state.isClosed {
                    break
                }
            }
            return wroteOutput
        }

        if let data = response.rawStdout ?? response.stdoutBase64.flatMap({ Data(base64Encoded: $0) }),
           !data.isEmpty,
           forwardNonTTYChunk(
            event: ProcOutputEvent(kind: .stdout, data: data),
            session: session,
            connectionID: connectionID,
            procID: procID,
            state: state,
            outputQueue: outputQueue
           )
        {
            wroteOutput = true
        }
        if !hasOrderedChunks,
           let data = response.rawStderr ?? response.stderrBase64.flatMap({ Data(base64Encoded: $0) }),
           !data.isEmpty,
           forwardNonTTYChunk(
            event: ProcOutputEvent(kind: .stderr, data: data),
            session: session,
            connectionID: connectionID,
            procID: procID,
            state: state,
            outputQueue: outputQueue
           )
        {
            wroteOutput = true
        }
        return wroteOutput
    }

    private func forwardNonTTYChunk(
        event: ProcOutputEvent,
        session: AttachedExecSession,
        connectionID: String,
        procID: String,
        state: BridgeState,
        outputQueue: AttachedExecOutputQueue
    ) -> Bool {
        let mux = attachedNonTTYMuxFrame(for: event)
        let stream = mux.stream
        let data = mux.payload
        guard attachedShouldForwardStream(
            tty: false,
            attachStdout: session.attachStdout,
            attachStderr: session.attachStderr,
            stream: stream
        ) else {
            return false
        }

        logger.log(stream == "stdout" ? "attached_proc_stdout" : "attached_proc_stderr", fields: [
            "connection_id": connectionID,
            "exec_id": session.execID,
            "proc_id": procID,
            "bytes": String(data.count),
            "preview": previewBytes(data)
        ])
        logger.log("attached_exec_mux_server_bytes", fields: muxDiagnosticFields(
            connectionID: connectionID,
            execID: session.execID,
            procID: procID,
            direction: "server",
            stream: stream,
            frame: mux.framed,
            payload: data
        ))
        outputQueue.push(AttachedExecOutputFrame(stream: stream, payload: data, framed: mux.framed))
        return true
    }

    private func forwardImmediateNonTTYChunk(
        fd: Int32,
        event: ProcOutputEvent,
        session: AttachedExecSession,
        connectionID: String,
        procID: String,
        immediateMuxWriter: AttachedImmediateMuxWriter?
    ) -> Bool {
        let execKind = attachedExecKind(session: session)
        let mux = attachedNonTTYMuxFrame(for: event)
        let stream = mux.stream
        let data = mux.payload
        guard attachedShouldForwardStream(
            tty: false,
            attachStdout: session.attachStdout,
            attachStderr: session.attachStderr,
            stream: stream
        ) else {
            return true
        }

        logger.log(stream == "stdout" ? "attached_proc_stdout" : "attached_proc_stderr", fields: [
            "connection_id": connectionID,
            "exec_id": session.execID,
            "proc_id": procID,
            "exec_kind": execKind.rawValue,
            "bytes": String(data.count),
            "preview": previewBytes(data)
        ])
        logger.log("attached_exec_mux_server_bytes", fields: muxDiagnosticFields(
            connectionID: connectionID,
            execID: session.execID,
            procID: procID,
            direction: "server",
            stream: stream,
            frame: mux.framed,
            payload: data
        ))
        if let immediateMuxWriter {
            if !immediateMuxWriter.append(
                stream: stream,
                payload: data,
                framed: mux.framed,
                fd: fd
            ) {
                logger.log("attached_exec_bridge_write_failed", fields: [
                    "connection_id": connectionID,
                    "exec_id": session.execID,
                    "proc_id": procID,
                    "stream": stream,
                    "bytes": String(data.count)
                ])
                return false
            }
            return true
        }
        if !writeData(fd, data: mux.framed) {
            logger.log("attached_exec_bridge_write_failed", fields: [
                "connection_id": connectionID,
                "exec_id": session.execID,
                "proc_id": procID,
                "stream": stream,
                "bytes": String(data.count)
            ])
            return false
        }
        return true
    }

    private func runNonTTYSocketWriter(
        fd: Int32,
        outputQueue: AttachedExecOutputQueue,
        state: BridgeState,
        failureBox: AttachedExecBridgeWriteFailure,
        session: AttachedExecSession,
        connectionID: String,
        procID: String
    ) {
        while let frame = outputQueue.pop() {
            guard writeData(fd, data: frame.framed) else {
                logger.log("attached_exec_bridge_write_failed", fields: [
                    "connection_id": connectionID,
                    "exec_id": session.execID,
                    "proc_id": procID,
                    "stream": frame.stream,
                    "bytes": String(frame.payload.count)
                ])
                failureBox.message = "attached exec bridge socket write failed"
                state.close()
                outputQueue.close()
                return
            }
        }
    }

    private func classifyBridgeFailureReason(_ error: Error) -> String {
        let text = String(describing: error).lowercased()
        if text.contains("failed to open attached pty") {
            return "guest_shell_unavailable"
        }
        if text.contains("daemon unavailable")
            || text.contains("failed to connect")
            || text.contains("connection")
        {
            return "vsock_connect_failed"
        }
        return "bridge_error"
    }

    private func isNonFatalProcReadTimeout(_ error: Error) -> Bool {
        let text = String(describing: error).lowercased()
        return text.contains("vsock read timeout") && text.contains("op=proc_read")
    }

    private func scheduleProcClose(
        instance: String,
        procID: String,
        sessionID: String
    ) {
        logger.log("attached_proc_close_deferred", fields: [
            "instance": instance,
            "proc_id": procID,
            "session_id": sessionID
        ])
        let paths = self.paths
        let lock = self.lock
        let store = self.store
        let logger = self.logger
        let executablePath = self.executablePath
        let thread = Thread {
            let client = DaemonClient(
                paths: paths,
                lock: lock,
                store: store,
                logger: logger,
                executablePath: executablePath
            )
            defer { client.disconnect() }
            do {
                try client.ensureConnected(expectedInstanceName: instance)
                _ = try client.sendIndependentOneShot(RuntimeControlRequest(
                    op: "proc_close",
                    timeoutMs: 250,
                    procId: procID,
                    sessionId: sessionID
                ))
                logger.log("attached_proc_close_deferred_finished", fields: [
                    "instance": instance,
                    "proc_id": procID,
                    "session_id": sessionID,
                    "result": "ok"
                ])
            } catch {
                logger.log("attached_proc_close_deferred_finished", fields: [
                    "instance": instance,
                    "proc_id": procID,
                    "session_id": sessionID,
                    "result": "ignored_error",
                    "error": String(describing: error)
                ])
            }
        }
        thread.name = "msl.attached.proc.close"
        thread.start()
    }

    private func schedulePtyClose(
        instance: String,
        ptyID: String,
        sessionID: String
    ) {
        logger.log("attached_pty_close_deferred", fields: [
            "instance": instance,
            "pty_id": ptyID,
            "session_id": sessionID
        ])
        let paths = self.paths
        let lock = self.lock
        let store = self.store
        let logger = self.logger
        let executablePath = self.executablePath
        let thread = Thread {
            let client = DaemonClient(
                paths: paths,
                lock: lock,
                store: store,
                logger: logger,
                executablePath: executablePath
            )
            defer { client.disconnect() }
            do {
                try client.ensureConnected(expectedInstanceName: instance)
                _ = try client.sendIndependentOneShot(RuntimeControlRequest(
                    op: "pty_close",
                    timeoutMs: 250,
                    ptyId: ptyID,
                    sessionId: sessionID
                ))
                logger.log("attached_pty_close_deferred_finished", fields: [
                    "instance": instance,
                    "pty_id": ptyID,
                    "session_id": sessionID,
                    "result": "ok"
                ])
            } catch {
                logger.log("attached_pty_close_deferred_finished", fields: [
                    "instance": instance,
                    "pty_id": ptyID,
                    "session_id": sessionID,
                    "result": "ignored_error",
                    "error": String(describing: error)
                ])
            }
        }
        thread.name = "msl.attached.pty.close"
        thread.start()
    }

    private func relayClientInput(
        fd: Int32,
        daemonClient: DaemonClient,
        ptyID: String,
        sessionID: String,
        state: BridgeState,
        initialBytes: Data
    ) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        if !initialBytes.isEmpty {
            _ = try? daemonClient.send(RuntimeControlRequest(
                op: "pty_write",
                ptyId: ptyID,
                rawData: initialBytes,
                sessionId: sessionID
            ))
        }
        while !state.isClosed {
            let n = read(fd, &buffer, buffer.count)
            if n == 0 {
                _ = state.closeStdin()
                break
            }
            if n < 0 {
                if errno == EINTR {
                    continue
                }
                break
            }
            let chunk = Data(buffer[0..<Int(n)])
            _ = try? daemonClient.send(RuntimeControlRequest(
                op: "pty_write",
                ptyId: ptyID,
                rawData: chunk,
                sessionId: sessionID
            ))
        }
    }

    private func relayClientInput(
        fd: Int32,
        daemonClient: DaemonClient,
        procID: String,
        sessionID: String,
        state: BridgeState,
        initialBytes: Data,
        connectionID: String,
        shellSentinelTracker: ShellServerSentinelTracker?
    ) {
        // VS Code Server upload is dominated by host-side chunking. InitChannel
        // is already framed/raw for proc_write, so use larger batches here and
        // let RuntimeControl carry fewer, bigger writes.
        let maxBatchBytes = 1024 * 1024
        let coalescePollMs = 5
        var buffer = [UInt8](repeating: 0, count: maxBatchBytes)
        let writerClient = try? daemonClient.makeIndependentPersistentClient()
        defer { writerClient?.disconnect() }
        if !initialBytes.isEmpty {
            sendProcInputChunk(
                chunk: initialBytes,
                daemonClient: daemonClient,
                writerClient: writerClient,
                procID: procID,
                sessionID: sessionID,
                connectionID: connectionID,
                state: state,
                shellSentinelTracker: shellSentinelTracker
            )
        }
        while !state.isClosed {
            let n = read(fd, &buffer, buffer.count)
            if n == 0 {
                closeProcInput(
                    daemonClient: daemonClient,
                    procID: procID,
                    sessionID: sessionID,
                    state: state,
                    reason: "client_eof"
                )
                break
            }
            if n < 0 {
                if errno == EINTR {
                    continue
                }
                closeProcInput(
                    daemonClient: daemonClient,
                    procID: procID,
                    sessionID: sessionID,
                    state: state,
                    reason: "client_read_error",
                    errnoValue: errno
                )
                break
            }
            var chunk = Data(buffer[0..<Int(n)])
            while chunk.count < maxBatchBytes && !state.isClosed {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, Int32(coalescePollMs))
                if ready <= 0 || (pfd.revents & Int16(POLLIN)) == 0 {
                    break
                }
                let remaining = min(buffer.count, maxBatchBytes - chunk.count)
                let extra = chunk.withUnsafeMutableBytes { _ -> Int in
                    read(fd, &buffer, remaining)
                }
                if extra == 0 {
                    closeProcInput(
                        daemonClient: daemonClient,
                        procID: procID,
                        sessionID: sessionID,
                        state: state,
                        reason: "client_eof"
                    )
                    break
                }
                if extra < 0 {
                    if errno == EINTR {
                        continue
                    }
                    closeProcInput(
                        daemonClient: daemonClient,
                        procID: procID,
                        sessionID: sessionID,
                        state: state,
                        reason: "client_read_error",
                        errnoValue: errno
                    )
                    break
                }
                chunk.append(buffer, count: extra)
            }
            if chunk.isEmpty {
                continue
            }
            sendProcInputChunk(
                chunk: chunk,
                daemonClient: daemonClient,
                writerClient: writerClient,
                procID: procID,
                sessionID: sessionID,
                connectionID: connectionID,
                state: state,
                shellSentinelTracker: shellSentinelTracker
            )
        }
    }

    private func sendProcInputChunk(
        chunk: Data,
        daemonClient: DaemonClient,
        writerClient: RuntimeControlClient?,
        procID: String,
        sessionID: String,
        connectionID: String,
        state: BridgeState,
        shellSentinelTracker: ShellServerSentinelTracker?
    ) {
        shellSentinelTracker?.consume(stream: .stdin, data: chunk)
        if chunk.count >= 32 * 1024 && !isLikelyTextBytes(chunk) {
            state.markBulkTransfer()
        }
        if chunk.count <= 4096 {
            logger.log("attached_proc_stdin", fields: [
                "connection_id": connectionID,
                "proc_id": procID,
                "session_id": sessionID,
                "bytes": String(chunk.count),
                "preview": previewBytes(chunk)
            ])
        } else {
            logger.log("attached_proc_stdin", fields: [
                "connection_id": connectionID,
                "proc_id": procID,
                "session_id": sessionID,
                "bytes": String(chunk.count),
                "preview": "<binary>"
            ])
        }
        logger.log("attached_exec_mux_client_bytes", fields: [
            "connection_id": connectionID,
            "proc_id": procID,
            "session_id": sessionID,
            "direction": "client",
            "bytes": String(chunk.count),
            "preview": previewBytes(chunk),
            "preview_hex": previewHexBytes(chunk),
            "is_likely_text": isLikelyTextBytes(chunk) ? "true" : "false"
        ])
        let startedAt = Date()
        do {
            let request = RuntimeControlRequest(
                op: "proc_write",
                timeoutMs: 30_000,
                procId: procID,
                rawData: chunk,
                sessionId: sessionID
            )
            let response = try (writerClient?.sendPersistent(request) ?? daemonClient.sendIndependentOneShot(request))
            guard response.ok else {
                throw MSLRuntimeError(response.error ?? "proc_write failed")
            }
            logger.log("attached_proc_write_timing", fields: [
                "connection_id": connectionID,
                "proc_id": procID,
                "session_id": sessionID,
                "bytes": String(chunk.count),
                "runtime_control_ms": String(Int(Date().timeIntervalSince(startedAt) * 1000)),
                "ok": "true",
                "mode": writerClient == nil ? "sync_independent_one_shot" : "sync_independent_persistent",
                "error": ""
            ])
        } catch {
            logger.log("attached_proc_write_timing", fields: [
                "connection_id": connectionID,
                "proc_id": procID,
                "session_id": sessionID,
                "bytes": String(chunk.count),
                "runtime_control_ms": String(Int(Date().timeIntervalSince(startedAt) * 1000)),
                "ok": "false",
                "mode": writerClient == nil ? "sync_independent_one_shot" : "sync_independent_persistent",
                "error": String(describing: error)
            ])
            state.close()
        }
    }

    private func closeProcInput(
        daemonClient: DaemonClient,
        procID: String,
        sessionID: String,
        state: BridgeState,
        reason: String,
        errnoValue: Int32? = nil
    ) {
        guard state.closeStdin() else {
            return
        }
        var fields: [String: String] = [
            "proc_id": procID,
            "session_id": sessionID,
            "reason": reason
        ]
        if let errnoValue {
            fields["errno"] = String(errnoValue)
        }
        logger.log("attached_proc_stdin_closed", fields: fields)
        _ = try? daemonClient.send(RuntimeControlRequest(
            op: "proc_stdin_close",
            procId: procID,
            sessionId: sessionID
        ))
    }

    private func readHTTPRequest(fd: Int32, bufferedData: Data = Data()) -> HTTPRequestReadResult {
        var data = bufferedData
        var headerEndRange: Range<Data.Index>?
        let maxHeader = 128 * 1024
        var buffer = [UInt8](repeating: 0, count: 4096)

        if !data.isEmpty {
            headerEndRange = data.range(of: Data([13, 10, 13, 10]))
        }

        while headerEndRange == nil {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 {
                if n == 0 {
                    if data.isEmpty {
                        return .closed(bytesRead: 0)
                    }
                    return .failure(reason: "eof_before_headers", bytesRead: data.count)
                }
                return .failure(reason: "read_error:\(lastErr())", bytesRead: data.count)
            }
            data.append(buffer, count: n)
            if data.count > maxHeader {
                return .failure(reason: "header_too_large", bytesRead: data.count)
            }
            headerEndRange = data.range(of: Data([13, 10, 13, 10]))
        }

        guard let headerRange = headerEndRange else {
            return .failure(reason: "header_terminator_missing", bytesRead: data.count)
        }
        let headerData = data[data.startIndex..<headerRange.lowerBound]
        let bodyStart = headerRange.upperBound
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .failure(reason: "invalid_header_encoding", bytesRead: data.count)
        }
        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .failure(reason: "missing_request_line", bytesRead: data.count)
        }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            return .failure(reason: "invalid_request_line", bytesRead: data.count)
        }
        let method = String(parts[0])
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let key = line[..<idx].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        var body = Data(data[bodyStart...])
        while body.count < contentLength {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 {
                if n == 0 {
                    return .failure(reason: "incomplete_body_eof", bytesRead: data.count)
                }
                return .failure(reason: "body_read_error:\(lastErr())", bytesRead: data.count)
            }
            body.append(buffer, count: n)
        }
        if body.count < contentLength {
            return .failure(reason: "incomplete_body", bytesRead: data.count + body.count)
        }
        var remaining = Data()
        if contentLength >= 0 && body.count > contentLength {
            remaining = body.subdata(in: contentLength..<body.count)
            body = body.subdata(in: 0..<contentLength)
        }

        return .success(
            HTTPRequest(method: method, path: path, headers: headers, body: body),
            remaining: remaining
        )
    }

    private func peerIdentity(fd: Int32) -> (uid: String, gid: String) {
        var uid: uid_t = 0
        var gid: gid_t = 0
        if getpeereid(fd, &uid, &gid) == 0 {
            return (String(uid), String(gid))
        }
        return ("unknown", "unknown")
    }

    private func writeJSONResponse(fd: Int32, status: Int, body: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body, options: []) else {
            _ = writeRaw(fd, "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n")
            return
        }
        writeHTTPResponse(
            fd: fd,
            status: status,
            contentType: "application/json",
            body: data + Data("\n".utf8),
            transferMode: .chunked
        )
    }

    private func writeJSONArray(fd: Int32, status: Int, body: [[String: Any]]) {
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body, options: []) else {
            _ = writeRaw(fd, "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n")
            return
        }
        writeHTTPResponse(
            fd: fd,
            status: status,
            contentType: "application/json",
            body: data + Data("\n".utf8),
            transferMode: .chunked
        )
    }

    private func writeHTTPResponse(
        fd: Int32,
        status: Int,
        contentType: String,
        body: Data,
        includeBody: Bool = true,
        transferMode: AttachedHTTPResponseTransferMode = .contentLength
    ) {
        let header = attachedHTTPResponseHeader(
            status: status,
            contentType: contentType,
            bodyLength: body.count,
            transferMode: transferMode
        )
        _ = writeRaw(fd, header)
        if includeBody {
            switch transferMode {
            case .contentLength:
                _ = writeData(fd, data: body)
            case .chunked:
                _ = writeChunk(fd, data: body)
                _ = writeRaw(fd, "0\r\n\r\n")
            }
        }
    }

    private func writeChunk(_ fd: Int32, data: Data) -> Bool {
        guard writeRaw(fd, String(data.count, radix: 16) + "\r\n") else {
            return false
        }
        guard writeData(fd, data: data) else {
            return false
        }
        return writeRaw(fd, "\r\n")
    }

    @discardableResult
    private func writeRaw(_ fd: Int32, _ text: String) -> Bool {
        writeData(fd, data: Data(text.utf8))
    }

    @discardableResult
    private func writeData(_ fd: Int32, data: Data) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            while offset < raw.count {
                let ptr = base.advanced(by: offset)
                let n = write(fd, ptr, raw.count - offset)
                if n <= 0 {
                    return false
                }
                offset += n
            }
            return true
        }
    }

    private func match(path: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let nsrange = NSRange(path.startIndex..<path.endIndex, in: path)
        guard let match = regex.firstMatch(in: path, options: [], range: nsrange),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: path) else {
            return nil
        }
        return String(path[range])
    }

    private func lastErr() -> String {
        String(cString: strerror(errno))
    }

    private func attachedExecPID(from execID: String) -> Int {
        let prefix = String(execID.prefix(7))
        return (Int(prefix, radix: 16) ?? 2048) % 30_000 + 1000
    }
}

private func previewBytes(_ data: Data, limit: Int = 80) -> String {
    let prefix = data.prefix(limit)
    var out = ""
    out.reserveCapacity(prefix.count)
    for byte in prefix {
        switch byte {
        case 0x20...0x7e:
            out.append(Character(UnicodeScalar(byte)))
        case 0x0a:
            out.append("\\n")
        case 0x0d:
            out.append("\\r")
        case 0x09:
            out.append("\\t")
        default:
            out.append(String(format: "\\x%02x", byte))
        }
    }
    if data.count > limit {
        out.append("...")
    }
    return out
}

private func previewHexBytes(_ data: Data, limit: Int = 32) -> String {
    data.prefix(limit).map { String(format: "%02x", $0) }.joined()
}

private func isLikelyTextBytes(_ data: Data) -> Bool {
    !data.contains { byte in
        switch byte {
        case 0x09, 0x0a, 0x0d, 0x20...0x7e:
            return false
        default:
            return true
        }
    }
}

private func muxDiagnosticFields(
    connectionID: String,
    execID: String,
    procID: String,
    direction: String,
    stream: String,
    frame: Data,
    payload: Data
) -> [String: String] {
    let header = frame.prefix(8)
    return [
        "connection_id": connectionID,
        "exec_id": execID,
        "proc_id": procID,
        "direction": direction,
        "stream": stream,
        "frame_bytes": String(frame.count),
        "payload_bytes": String(payload.count),
        "header_hex": previewHexBytes(Data(header), limit: 8),
        "frame_preview_hex": previewHexBytes(frame),
        "payload_preview": previewBytes(payload),
        "payload_preview_hex": previewHexBytes(payload),
        "payload_is_likely_text": isLikelyTextBytes(payload) ? "true" : "false"
    ]
}

private func heredocWriteScript(path: String, contents: String) -> String {
    let delimiter = "EOF-\(UUID().uuidString)"
    return """
    cat <<'\(delimiter)' > '\(path)'
    \(contents)
    \(delimiter)
    """
}

private struct AttachedExecCreateRequest: Decodable {
    var AttachStdin: Bool?
    var AttachStdout: Bool?
    var AttachStderr: Bool?
    var Cmd: [String]?
    var Env: [String]?
    var WorkingDir: String?
    var Tty: Bool?
    var DetachKeys: String?
    var User: String?
    var Privileged: Bool?
}

private struct AttachedExecStartRequest: Decodable {
    var Detach: Bool?
    var Tty: Bool?
}

func attachedValidateExecCreateRequest(cmd: [String]?) -> String? {
    guard let cmd else { return nil }
    guard !cmd.isEmpty else {
        return "missing_cmd"
    }
    guard !cmd[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return "missing_cmd"
    }
    return nil
}

func attachedValidateExecStartRequest(detach: Bool?, requestedTTY: Bool?, sessionTTY: Bool) -> String? {
    if detach == true {
        return "detach_not_supported"
    }
    if let requestedTTY, requestedTTY != sessionTTY {
        return "tty_mismatch"
    }
    return nil
}

func attachedExecStartContentType(tty: Bool) -> String {
    tty ? "application/vnd.docker.raw-stream" : "application/vnd.docker.multiplexed-stream"
}

func attachedShouldPumpInput(attachStdin: Bool) -> Bool {
    attachStdin
}

enum AttachedExecConnectionMode: Equatable {
    case finiteOneShot
    case persistent

    var logValue: String {
        switch self {
        case .finiteOneShot:
            return "finite_one_shot"
        case .persistent:
            return "persistent"
        }
    }
}

enum AttachedExecConnectionCloseDisposition {
    case deferred
    case closed
}

func attachedExecConnectionMode(session: AttachedExecSession) -> AttachedExecConnectionMode {
    if !session.tty, !session.attachStdin {
        return .finiteOneShot
    }
    return .persistent
}

func attachedShouldForwardStream(tty: Bool, attachStdout: Bool, attachStderr: Bool, stream: String) -> Bool {
    if tty {
        return attachStdout || attachStderr
    }
    switch stream {
    case "stdout":
        return attachStdout
    case "stderr":
        return attachStderr
    default:
        return false
    }
}

private final class BridgeState {
    private let lock = NSLock()
    private var closedValue = false
    private var stdinClosedValue = false
    private var bulkTransferActiveValue = false

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closedValue
    }

    var isStdinClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stdinClosedValue
    }

    var isBulkTransferActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return bulkTransferActiveValue
    }

    func close() {
        lock.lock()
        closedValue = true
        lock.unlock()
    }

    func closeStdin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if stdinClosedValue {
            return false
        }
        stdinClosedValue = true
        return true
    }

    func markBulkTransfer() {
        lock.lock()
        bulkTransferActiveValue = true
        lock.unlock()
    }

    func clearBulkTransfer() {
        lock.lock()
        bulkTransferActiveValue = false
        lock.unlock()
    }
}

private final class AttachedExecOutputQueue {
    private let condition = NSCondition()
    private var frames: [AttachedExecOutputFrame] = []
    private var closed = false

    func push(_ frame: AttachedExecOutputFrame) {
        condition.lock()
        frames.append(frame)
        condition.signal()
        condition.unlock()
    }

    func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    func pop() -> AttachedExecOutputFrame? {
        condition.lock()
        defer { condition.unlock() }
        while frames.isEmpty && !closed {
            condition.wait()
        }
        if !frames.isEmpty {
            return frames.removeFirst()
        }
        return nil
    }
}

private final class AttachedExecBridgeWriteFailure {
    private let lock = NSLock()
    private var value: String?

    var message: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }
}

func randomHex(length: Int) -> String {
    var result = ""
    while result.count < length {
        result += UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
    return String(result.prefix(length))
}

func dockerMuxFrame(streamID: UInt8, payload: Data) -> Data {
    var header = Data([streamID, 0, 0, 0])
    var length = UInt32(payload.count).bigEndian
    withUnsafeBytes(of: &length) { raw in
        header.append(contentsOf: raw)
    }
    var framed = Data()
    framed.reserveCapacity(header.count + payload.count)
    framed.append(header)
    framed.append(payload)
    return framed
}

func attachedWriteData(_ fd: Int32, data: Data) -> Bool {
    data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
            return true
        }
        var remaining = rawBuffer.count
        var offset = 0
        while remaining > 0 {
            let written = Darwin.write(fd, baseAddress.advanced(by: offset), remaining)
            if written < 0 {
                if errno == EINTR {
                    continue
                }
                return false
            }
            remaining -= written
            offset += written
        }
        return true
    }
}

func attachedNonTTYMuxFrame(for event: ProcOutputEvent) -> (stream: String, streamID: UInt8, payload: Data, framed: Data) {
    let stream: String
    let streamID: UInt8
    switch event.kind {
    case .stdout:
        stream = "stdout"
        streamID = 1
    case .stderr:
        stream = "stderr"
        streamID = 2
    }
    return (stream, streamID, event.data, dockerMuxFrame(streamID: streamID, payload: event.data))
}

final class AttachedImmediateMuxWriter {
    private let shellSentinelData = Data("\u{2404}".utf8)
    private let lock = NSLock()
    private let flushThresholdBytes = 16 * 1024
    private let directWriteThresholdBytes = 8 * 1024
    private let completionHoldbackUsec: useconds_t = 20_000
    private var pending = Data()
    private var pendingPayloadBytes = 0
    private var pendingCompletion = Data()
    private var completionFlushGeneration: UInt64 = 0

    func append(stream: String, payload: Data, framed: Data, fd: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if stream == "stdout", payload == shellSentinelData {
            if !flushLocked(fd: fd, includeCompletion: true) {
                return false
            }
            return attachedWriteData(fd, data: framed)
        }

        let split = splitPayload(stream: stream, payload: payload)

        if let normalPayload = split.normalPayload, !normalPayload.isEmpty {
            let normalFramed = dockerMuxFrame(streamID: stream == "stderr" ? 2 : 1, payload: normalPayload)
            if normalPayload.count >= directWriteThresholdBytes, split.completionPayload == nil {
                if !flushLocked(fd: fd, includeCompletion: false) {
                    return false
                }
                if !attachedWriteData(fd, data: normalFramed) {
                    return false
                }
            } else {
                pending.append(normalFramed)
                pendingPayloadBytes += normalPayload.count
                if shouldFlushNormal(stream: stream, payload: normalPayload) || pendingPayloadBytes >= flushThresholdBytes {
                    if !flushLocked(fd: fd, includeCompletion: false) {
                        return false
                    }
                }
            }
        }

        if let completionPayload = split.completionPayload, !completionPayload.isEmpty {
            let completionFramed = dockerMuxFrame(streamID: stream == "stderr" ? 2 : 1, payload: completionPayload)
            pendingCompletion.append(completionFramed)
            scheduleCompletionFlush(fd: fd)
        }
        return true
    }

    func flushPending(fd: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return flushLocked(fd: fd, includeCompletion: true)
    }

    private func shouldFlushNormal(stream: String, payload: Data) -> Bool {
        if stream == "stderr" {
            return true
        }
        if payload.count >= directWriteThresholdBytes {
            return true
        }
        return false
    }

    private func flushLocked(fd: Int32, includeCompletion: Bool) -> Bool {
        let normalBatch = pending
        let completionBatch = includeCompletion ? pendingCompletion : Data()
        guard !normalBatch.isEmpty || !completionBatch.isEmpty else {
            return true
        }
        pending.removeAll(keepingCapacity: true)
        pendingPayloadBytes = 0
        if includeCompletion {
            pendingCompletion.removeAll(keepingCapacity: true)
        }
        if !normalBatch.isEmpty, !attachedWriteData(fd, data: normalBatch) {
            return false
        }
        if !completionBatch.isEmpty, !attachedWriteData(fd, data: completionBatch) {
            return false
        }
        return true
    }

    private func scheduleCompletionFlush(fd: Int32) {
        completionFlushGeneration &+= 1
        let generation = completionFlushGeneration
        let thread = Thread { [weak self] in
            guard let self else { return }
            usleep(self.completionHoldbackUsec)
            self.flushCompletionIfCurrent(fd: fd, generation: generation)
        }
        thread.name = "msl.attached.shell-completion"
        thread.start()
    }

    private func flushCompletionIfCurrent(fd: Int32, generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard generation == completionFlushGeneration, !pendingCompletion.isEmpty else {
            return
        }
        _ = flushLocked(fd: fd, includeCompletion: true)
    }

    private func splitPayload(stream: String, payload: Data) -> (normalPayload: Data?, completionPayload: Data?) {
        if stream == "stdout" {
            if payload == shellSentinelData {
                return (nil, payload)
            }
            if let range = stdoutExitSentinelRange(in: payload) {
                let normal = range.lowerBound > 0 ? payload.subdata(in: 0..<range.lowerBound) : nil
                let completion = payload.subdata(in: range)
                return (normal, completion)
            }
            return (payload, nil)
        }

        if payload == shellSentinelData {
            return (nil, payload)
        }
        if payload.count > shellSentinelData.count, payload.suffix(shellSentinelData.count) == shellSentinelData {
            let normal = payload.subdata(in: 0..<(payload.count - shellSentinelData.count))
            return (normal.isEmpty ? nil : normal, shellSentinelData)
        }
        return (payload, nil)
    }

    private func stdoutExitSentinelRange(in payload: Data) -> Range<Int>? {
        let bytes = [UInt8](payload)
        let marker = [UInt8](shellSentinelData)
        let minimumLength = marker.count * 2 + 1
        guard bytes.count >= minimumLength else { return nil }
        let searchUpperBound = bytes.count - minimumLength
        for start in 0...searchUpperBound {
            guard Array(bytes[start..<(start + marker.count)]) == marker else {
                continue
            }
            guard Array(bytes[(bytes.count - marker.count)..<bytes.count]) == marker else {
                continue
            }
            let middleStart = start + marker.count
            let middleEnd = bytes.count - marker.count
            guard middleStart < middleEnd else { continue }
            let middle = bytes[middleStart..<middleEnd]
            if middle.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) {
                return start..<bytes.count
            }
        }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private enum ShellServerSentinelStream {
    case stdin
    case stdout
    case stderr
}

final class ShellServerMuxOrderer {
    private let eotData = Data("\u{2404}".utf8)
    private var pendingStderrSentinels: [Data] = []
    private var awaitingTrailingStderrAfterExit = false

    func consume(stream: String, data: Data) -> [(String, Data)] {
        guard !data.isEmpty else { return [] }
        if stream == "stderr", data == eotData {
            if awaitingTrailingStderrAfterExit {
                awaitingTrailingStderrAfterExit = false
                return [(stream, data)]
            }
            pendingStderrSentinels.append(data)
            return []
        }

        guard stream == "stdout" else {
            return [(stream, data)]
        }

        var output: [(String, Data)] = []
        if isPlainStartSentinel(data), !pendingStderrSentinels.isEmpty {
            output.append(contentsOf: flushPendingStderr())
        }
        output.append((stream, data))
        if isExitSentinel(data) {
            awaitingTrailingStderrAfterExit = true
            if !pendingStderrSentinels.isEmpty {
                awaitingTrailingStderrAfterExit = false
                output.append(contentsOf: flushPendingStderr())
            }
        } else if isPlainStartSentinel(data) {
            awaitingTrailingStderrAfterExit = false
        }
        return output
    }

    private func isPlainStartSentinel(_ data: Data) -> Bool {
        data == eotData
    }

    private func isExitSentinel(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        let marker = [UInt8](eotData)
        let minimumLength = marker.count * 2 + 1
        guard bytes.count >= minimumLength else { return false }
        let searchUpperBound = bytes.count - minimumLength
        for start in 0...searchUpperBound {
            let remaining = bytes.count - start
            if remaining < minimumLength {
                continue
            }
            guard Array(bytes[start..<(start + marker.count)]) == marker else {
                continue
            }
            guard Array(bytes[(bytes.count - marker.count)..<bytes.count]) == marker else {
                continue
            }
            let middleStart = start + marker.count
            let middleEnd = bytes.count - marker.count
            guard middleStart < middleEnd else { continue }
            let middle = bytes[middleStart..<middleEnd]
            if middle.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) {
                return true
            }
        }
        return false
    }

    private func flushPendingStderr() -> [(String, Data)] {
        defer { pendingStderrSentinels.removeAll(keepingCapacity: true) }
        return pendingStderrSentinels.map { ("stderr", $0) }
    }
}

private final class ShellServerSentinelTracker {
    private enum StdoutPhase {
        case waitingForStart
        case readingStdout
        case readingExitCode
    }

    private let eot = "\u{2404}"
    private let logger: MSLLogger
    private let connectionID: String
    private let execID: String
    private let procID: String
    private let traceID: String

    private var stdoutPhase: StdoutPhase = .waitingForStart
    private var currentCommandIndex = 1
    private var stdoutBuffer = ""
    private var exitCodeBuffer = ""
    private var stdinBuffer = ""
    private var commandQueue: [Int: String] = [:]
    private var pendingCompletion: (commandIndex: Int, exitCode: String, stdoutPreview: String)?
    private var pendingStderrSentinelCount = 0
    private var traceWindow: ClosedRange<Int>?
    private var traceReason: String?

    init(logger: MSLLogger, connectionID: String, execID: String, procID: String) {
        self.logger = logger
        self.connectionID = connectionID
        self.execID = execID
        self.procID = procID
        self.traceID = "\(connectionID.prefix(8))-\(procID)"
    }

    func consume(stream: ShellServerSentinelStream, data: Data) {
        traceRawChunkIfNeeded(stream: stream, data: data)
        let text = String(decoding: data, as: UTF8.self)
        switch stream {
        case .stdin:
            consumeStdin(text)
        case .stdout:
            consumeStdout(text)
        case .stderr:
            consumeStderr(text)
        }
    }

    private func consumeStdin(_ text: String) {
        stdinBuffer.append(text)
        let startMarker = "echo -n \(eot); ( "
        let endMarker = " ); echo -n \(eot)$?\(eot); echo -n \(eot) >&2"
        while let startRange = stdinBuffer.range(of: startMarker),
              let endRange = stdinBuffer.range(of: endMarker, range: startRange.upperBound..<stdinBuffer.endIndex) {
            let command = String(stdinBuffer[startRange.upperBound..<endRange.lowerBound])
            let commandIndex = currentCommandIndex
            commandQueue[commandIndex] = command
            activateTraceIfNeeded(commandIndex: commandIndex, command: command)
            logger.log("attached_shell_command_enqueued", fields: [
                "connection_id": connectionID,
                "exec_id": execID,
                "proc_id": procID,
                "command_index": String(commandIndex),
                "command_preview": limitedPreview(command)
            ])
            if shouldTrace(commandIndex: commandIndex) {
                logger.log("attached_shell_trace", fields: traceFields(
                    commandIndex: commandIndex,
                    phase: "stdin_enqueued",
                    extra: [
                        "command_preview": limitedPreview(command)
                    ]
                ))
            }
            stdinBuffer.removeSubrange(stdinBuffer.startIndex..<endRange.upperBound)
        }
        if stdinBuffer.count > 32_768 {
            stdinBuffer = String(stdinBuffer.suffix(32_768))
        }
    }

    private func consumeStdout(_ text: String) {
        for scalar in text.unicodeScalars {
            if scalar == eot.unicodeScalars.first {
                switch stdoutPhase {
                case .waitingForStart:
                    logger.log("attached_shell_stdout_sentinel", fields: baseFields(commandIndex: currentCommandIndex))
                    logTrace(
                        commandIndex: currentCommandIndex,
                        phase: "stdout_sentinel"
                    )
                    stdoutPhase = .readingStdout
                case .readingStdout:
                    logger.log("attached_shell_exit_code_sentinel", fields: baseFields(commandIndex: currentCommandIndex).merging([
                        "phase": "begin",
                        "stdout_preview": limitedPreview(stdoutBuffer)
                    ]) { _, new in new })
                    logTrace(
                        commandIndex: currentCommandIndex,
                        phase: "stdout_exit_begin",
                        extra: ["stdout_preview": limitedPreview(stdoutBuffer)]
                    )
                    stdoutPhase = .readingExitCode
                case .readingExitCode:
                    let exitCode = exitCodeBuffer.nilIfEmpty ?? "0"
                    logger.log("attached_shell_exit_code_sentinel", fields: baseFields(commandIndex: currentCommandIndex).merging([
                        "phase": "end",
                        "exit_code": exitCode,
                        "stdout_preview": limitedPreview(stdoutBuffer)
                    ]) { _, new in new })
                    logTrace(
                        commandIndex: currentCommandIndex,
                        phase: "stdout_exit_end",
                        extra: [
                            "exit_code": exitCode,
                            "stdout_preview": limitedPreview(stdoutBuffer)
                        ]
                    )
                    pendingCompletion = (
                        commandIndex: currentCommandIndex,
                        exitCode: exitCode,
                        stdoutPreview: limitedPreview(stdoutBuffer)
                    )
                    currentCommandIndex += 1
                    stdoutBuffer.removeAll(keepingCapacity: true)
                    exitCodeBuffer.removeAll(keepingCapacity: true)
                    stdoutPhase = .waitingForStart
                    drainPendingCompletionIfReady()
                }
            } else {
                switch stdoutPhase {
                case .waitingForStart:
                    continue
                case .readingStdout:
                    stdoutBuffer.unicodeScalars.append(scalar)
                case .readingExitCode:
                    exitCodeBuffer.unicodeScalars.append(scalar)
                }
            }
        }
    }

    private func consumeStderr(_ text: String) {
        for scalar in text.unicodeScalars {
            guard scalar == eot.unicodeScalars.first else {
                continue
            }
            guard pendingCompletion != nil else {
                pendingStderrSentinelCount += 1
                logger.log("attached_shell_stderr_sentinel_buffered", fields: baseFields(commandIndex: max(currentCommandIndex - 1, 1)).merging([
                    "buffered_count": String(pendingStderrSentinelCount)
                ]) { _, new in new })
                logTrace(
                    commandIndex: max(currentCommandIndex - 1, 1),
                    phase: "stderr_sentinel_buffered",
                    extra: ["buffered_count": String(pendingStderrSentinelCount)]
                )
                continue
            }
            pendingStderrSentinelCount += 1
            drainPendingCompletionIfReady()
        }
    }

    private func drainPendingCompletionIfReady() {
        guard pendingStderrSentinelCount > 0, let completion = pendingCompletion else {
            return
        }
        pendingStderrSentinelCount -= 1
        logger.log("attached_shell_stderr_sentinel", fields: baseFields(commandIndex: completion.commandIndex))
        logTrace(commandIndex: completion.commandIndex, phase: "stderr_sentinel")
        if let command = commandQueue[completion.commandIndex] {
            logger.log("attached_shell_command_complete", fields: [
                "connection_id": connectionID,
                "exec_id": execID,
                "proc_id": procID,
                "command_index": String(completion.commandIndex),
                "exit_code": completion.exitCode,
                "stdout_preview": completion.stdoutPreview,
                "command_preview": limitedPreview(command)
            ])
            logTrace(
                commandIndex: completion.commandIndex,
                phase: "command_complete",
                extra: [
                    "exit_code": completion.exitCode,
                    "stdout_preview": completion.stdoutPreview,
                    "command_preview": limitedPreview(command)
                ]
            )
            commandQueue.removeValue(forKey: completion.commandIndex)
        } else {
            logger.log("attached_shell_command_complete", fields: [
                "connection_id": connectionID,
                "exec_id": execID,
                "proc_id": procID,
                "command_index": String(completion.commandIndex),
                "exit_code": completion.exitCode,
                "stdout_preview": completion.stdoutPreview
            ])
            logTrace(
                commandIndex: completion.commandIndex,
                phase: "command_complete",
                extra: [
                    "exit_code": completion.exitCode,
                    "stdout_preview": completion.stdoutPreview
                ]
            )
        }
        pendingCompletion = nil
    }

    private func activateTraceIfNeeded(commandIndex: Int, command: String) {
        guard traceWindow == nil else { return }
        let lowered = command.lowercased()
        let trigger: String?
        if lowered.contains("known_hosts") {
            trigger = "known_hosts"
        } else if lowered.contains("credential.helper") {
            trigger = "credential_helper"
        } else if lowered.contains("product.json") {
            trigger = "product_json"
        } else {
            trigger = nil
        }
        guard let trigger else { return }
        let lowerBound = max(commandIndex - 1, 1)
        traceWindow = lowerBound...(commandIndex + 2)
        traceReason = trigger
        logger.log("attached_shell_trace_started", fields: [
            "connection_id": connectionID,
            "exec_id": execID,
            "proc_id": procID,
            "trace_id": traceID,
            "trigger": trigger,
            "start_command_index": String(lowerBound),
            "end_command_index": String(commandIndex + 2),
            "command_index": String(commandIndex),
            "command_preview": limitedPreview(command)
        ])
    }

    private func shouldTrace(commandIndex: Int) -> Bool {
        guard let traceWindow else { return false }
        return traceWindow.contains(commandIndex)
    }

    private func currentTraceCommandIndex(for stream: ShellServerSentinelStream) -> Int? {
        switch stream {
        case .stdin:
            return currentCommandIndex
        case .stdout:
            return pendingCompletion?.commandIndex ?? currentCommandIndex
        case .stderr:
            return pendingCompletion?.commandIndex ?? max(currentCommandIndex - 1, 1)
        }
    }

    private func traceRawChunkIfNeeded(stream: ShellServerSentinelStream, data: Data) {
        guard !data.isEmpty, let commandIndex = currentTraceCommandIndex(for: stream), shouldTrace(commandIndex: commandIndex) else {
            return
        }
        logger.log("attached_shell_trace_chunk", fields: traceFields(
            commandIndex: commandIndex,
            phase: "chunk",
            extra: [
                "stream": traceStreamName(stream),
                "bytes": String(data.count),
                "preview": previewBytes(data),
                "preview_hex": previewHexBytes(data),
                "is_likely_text": isLikelyTextBytes(data) ? "true" : "false"
            ]
        ))
    }

    private func logTrace(commandIndex: Int, phase: String, extra: [String: String] = [:]) {
        guard shouldTrace(commandIndex: commandIndex) else { return }
        logger.log("attached_shell_trace", fields: traceFields(
            commandIndex: commandIndex,
            phase: phase,
            extra: extra
        ))
    }

    private func traceFields(commandIndex: Int, phase: String, extra: [String: String]) -> [String: String] {
        baseFields(commandIndex: commandIndex).merging([
            "trace_id": traceID,
            "phase": phase,
            "trigger": traceReason ?? ""
        ]) { _, new in new }.merging(extra) { _, new in new }
    }

    private func traceStreamName(_ stream: ShellServerSentinelStream) -> String {
        switch stream {
        case .stdin:
            return "stdin"
        case .stdout:
            return "stdout"
        case .stderr:
            return "stderr"
        }
    }

    private func baseFields(commandIndex: Int) -> [String: String] {
        [
            "connection_id": connectionID,
            "exec_id": execID,
            "proc_id": procID,
            "command_index": String(commandIndex)
        ]
    }

    private func limitedPreview(_ text: String, limit: Int = 120) -> String {
        if text.count <= limit {
            return text
        }
        return String(text.prefix(limit)) + "..."
    }
}
