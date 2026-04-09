import Foundation

public enum VMState: String, Codable {
    case stopped = "Stopped"
    case running = "Running"
}

public enum RuntimeLifecycleState: String, Codable {
    case stopped
    case starting
    case running
    case stopping
    case error
}

public enum StartupStepStatus: String, Codable {
    case pending
    case inProgress = "in_progress"
    case completed
    case failed
}

public struct IdleTimerState: Codable {
    public var armed: Bool
    public var deadlineEpochMs: Int64?

    public init(armed: Bool = false, deadlineEpochMs: Int64? = nil) {
        self.armed = armed
        self.deadlineEpochMs = deadlineEpochMs
    }
}

public struct BootstrapState: Codable {
    public var completed: Bool
    public var phase: String

    public init(completed: Bool = false, phase: String = "none") {
        self.completed = completed
        self.phase = phase
    }
}

public struct RuntimeState: Codable {
    public var schemaVersion: Int
    public var distro: String
    public var vmState: VMState
    public var lifecycleState: RuntimeLifecycleState
    public var activeSessionCount: Int
    public var idleTimer: IdleTimerState
    public var lastTransitionEpochMs: Int64
    public var startupEpochMs: Int64?
    public var startupStep: Int?
    public var startupStepName: String?
    public var startupStepStatus: StartupStepStatus?
    public var bootstrap: BootstrapState
    public var runtimeHostPid: Int32?
    public var runtimeControlSocket: String?
    public var initChannel: InitChannelState?
    public var runtimeUser: RuntimeUserState?
    public var lastErrorCode: String?
    public var lastErrorMessage: String?
    // Step24 schema v2 fields (legacy fields stay for compatibility during migration).
    public var daemonHostPid: Int32?
    public var daemonControlSocket: String?
    public var daemonEventSocket: String?
    public var instances: [RuntimeInstanceState]?

    public static func initial(nowMs: Int64) -> RuntimeState {
        RuntimeState(
            schemaVersion: 3,
            distro: "default",
            vmState: .stopped,
            lifecycleState: .stopped,
            activeSessionCount: 0,
            idleTimer: IdleTimerState(),
            lastTransitionEpochMs: nowMs,
            startupEpochMs: nil,
            startupStep: nil,
            startupStepName: nil,
            startupStepStatus: nil,
            bootstrap: BootstrapState(),
            runtimeHostPid: nil,
            runtimeControlSocket: nil,
            initChannel: nil,
            runtimeUser: nil,
            lastErrorCode: nil,
            lastErrorMessage: nil,
            daemonHostPid: nil,
            daemonControlSocket: nil,
            daemonEventSocket: nil,
            instances: [
                RuntimeInstanceState(
                    instance: "default",
                    vmState: .stopped,
                    lifecycleState: .stopped,
                    activeSessionCount: 0,
                    idleTimer: IdleTimerState(),
                    runtimeUser: nil,
                    initChannel: nil,
                    runtimeHostPid: nil,
                    runtimeControlSocket: nil,
                    lastError: nil,
                    lastErrorCode: nil,
                    lastErrorMessage: nil,
                    startupEpochMs: nil,
                    startupStep: nil,
                    startupStepName: nil,
                    startupStepStatus: nil,
                    lastTransitionEpochMs: nowMs
                )
            ]
        )
    }

    public init(
        schemaVersion: Int,
        distro: String,
        vmState: VMState,
        lifecycleState: RuntimeLifecycleState? = nil,
        activeSessionCount: Int,
        idleTimer: IdleTimerState,
        lastTransitionEpochMs: Int64,
        startupEpochMs: Int? = nil,
        startupStep: Int? = nil,
        startupStepName: String? = nil,
        startupStepStatus: StartupStepStatus? = nil,
        bootstrap: BootstrapState = BootstrapState(),
        runtimeHostPid: Int32? = nil,
        runtimeControlSocket: String? = nil,
        initChannel: InitChannelState? = nil,
        runtimeUser: RuntimeUserState? = nil,
        lastErrorCode: String? = nil,
        lastErrorMessage: String? = nil,
        daemonHostPid: Int32? = nil,
        daemonControlSocket: String? = nil,
        daemonEventSocket: String? = nil,
        instances: [RuntimeInstanceState]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.distro = distro
        self.vmState = vmState
        self.lifecycleState = lifecycleState ?? (vmState == .running ? .running : .stopped)
        self.activeSessionCount = activeSessionCount
        self.idleTimer = idleTimer
        self.lastTransitionEpochMs = lastTransitionEpochMs
        self.startupEpochMs = startupEpochMs.map(Int64.init)
        self.startupStep = startupStep
        self.startupStepName = startupStepName
        self.startupStepStatus = startupStepStatus
        self.bootstrap = bootstrap
        self.runtimeHostPid = runtimeHostPid
        self.runtimeControlSocket = runtimeControlSocket
        self.initChannel = initChannel
        self.runtimeUser = runtimeUser
        self.lastErrorCode = lastErrorCode
        self.lastErrorMessage = lastErrorMessage
        self.daemonHostPid = daemonHostPid
        self.daemonControlSocket = daemonControlSocket
        self.daemonEventSocket = daemonEventSocket
        self.instances = instances
    }

    @discardableResult
    public mutating func normalizeSchemaV2(nowMs: Int64) -> Bool {
        var changed = false
        if schemaVersion < 3 {
            schemaVersion = 3
            changed = true
        }
        if lifecycleState == .running && vmState != .running {
            vmState = .running
            changed = true
        } else if lifecycleState != .running && vmState != .stopped {
            vmState = .stopped
            changed = true
        }
        if instances == nil || instances?.isEmpty == true {
            instances = [
                RuntimeInstanceState(
                    instance: distro,
                    vmState: vmState,
                    lifecycleState: lifecycleState,
                    activeSessionCount: activeSessionCount,
                    idleTimer: idleTimer,
                    runtimeUser: runtimeUser,
                    initChannel: initChannel,
                    runtimeHostPid: runtimeHostPid,
                    runtimeControlSocket: runtimeControlSocket,
                    lastError: lastErrorMessage,
                    lastErrorCode: lastErrorCode,
                    lastErrorMessage: lastErrorMessage,
                    startupEpochMs: startupEpochMs,
                    startupStep: startupStep,
                    startupStepName: startupStepName,
                    startupStepStatus: startupStepStatus,
                    lastTransitionEpochMs: lastTransitionEpochMs
                )
            ]
            changed = true
        } else if let currentEntries = instances {
            var merged: [String: RuntimeInstanceState] = [:]
            for entry in currentEntries {
                if let existing = merged[entry.instance] {
                    if entry.lastTransitionEpochMs > existing.lastTransitionEpochMs {
                        merged[entry.instance] = entry
                    } else if entry.lastTransitionEpochMs == existing.lastTransitionEpochMs,
                              entry.vmState == .running,
                              existing.vmState != .running {
                        merged[entry.instance] = entry
                    }
                } else {
                    merged[entry.instance] = entry
                }
            }

            // Keep legacy single-instance fields and v2 primary instance in sync.
            merged[distro] = RuntimeInstanceState(
                instance: distro,
                vmState: vmState,
                lifecycleState: lifecycleState,
                activeSessionCount: activeSessionCount,
                idleTimer: idleTimer,
                runtimeUser: runtimeUser,
                initChannel: initChannel,
                runtimeHostPid: runtimeHostPid,
                runtimeControlSocket: runtimeControlSocket,
                lastError: lastErrorMessage,
                lastErrorCode: lastErrorCode,
                lastErrorMessage: lastErrorMessage,
                startupEpochMs: startupEpochMs,
                startupStep: startupStep,
                startupStepName: startupStepName,
                startupStepStatus: startupStepStatus,
                lastTransitionEpochMs: lastTransitionEpochMs
            )

            var normalized: [RuntimeInstanceState] = []
            if let primary = merged[distro] {
                normalized.append(primary)
                merged.removeValue(forKey: distro)
            }
            normalized.append(contentsOf: merged.keys.sorted().compactMap { merged[$0] })

            if normalized.count != currentEntries.count {
                changed = true
            } else {
                for (lhs, rhs) in zip(normalized, currentEntries) {
                    if lhs.instance != rhs.instance
                        || lhs.vmState != rhs.vmState
                        || lhs.activeSessionCount != rhs.activeSessionCount
                        || lhs.idleTimer.armed != rhs.idleTimer.armed
                        || lhs.idleTimer.deadlineEpochMs != rhs.idleTimer.deadlineEpochMs
                        || lhs.runtimeHostPid != rhs.runtimeHostPid
                        || lhs.runtimeControlSocket != rhs.runtimeControlSocket
                        || lhs.lifecycleState != rhs.lifecycleState
                        || lhs.lastErrorMessage != rhs.lastErrorMessage
                        || lhs.startupStep != rhs.startupStep
                        || lhs.startupStepStatus != rhs.startupStepStatus {
                        changed = true
                        break
                    }
                }
            }
            instances = normalized
        }
        if daemonHostPid != runtimeHostPid {
            daemonHostPid = runtimeHostPid
            changed = true
        }
        if daemonControlSocket != runtimeControlSocket {
            daemonControlSocket = runtimeControlSocket
            changed = true
        }
        if lastTransitionEpochMs <= 0 {
            lastTransitionEpochMs = nowMs
            changed = true
        }
        if lastError != lastErrorMessage {
            lastError = lastErrorMessage
            changed = true
        }
        return changed
    }

    public var lastError: String? {
        get { lastErrorMessage }
        set { lastErrorMessage = newValue }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, distro, vmState, lifecycleState, activeSessionCount, idleTimer, lastTransitionEpochMs
        case startupEpochMs, startupStep, startupStepName, startupStepStatus
        case bootstrap, runtimeHostPid, runtimeControlSocket, initChannel, runtimeUser
        case lastErrorCode, lastErrorMessage, daemonHostPid, daemonControlSocket, daemonEventSocket, instances
        case lastError
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 2
        distro = try c.decodeIfPresent(String.self, forKey: .distro) ?? "default"
        vmState = try c.decodeIfPresent(VMState.self, forKey: .vmState) ?? .stopped
        lifecycleState = try c.decodeIfPresent(RuntimeLifecycleState.self, forKey: .lifecycleState)
            ?? (vmState == .running ? .running : .stopped)
        activeSessionCount = try c.decodeIfPresent(Int.self, forKey: .activeSessionCount) ?? 0
        idleTimer = try c.decodeIfPresent(IdleTimerState.self, forKey: .idleTimer) ?? IdleTimerState()
        lastTransitionEpochMs = try c.decodeIfPresent(Int64.self, forKey: .lastTransitionEpochMs) ?? nowEpochMs()
        startupEpochMs = try c.decodeIfPresent(Int64.self, forKey: .startupEpochMs)
        startupStep = try c.decodeIfPresent(Int.self, forKey: .startupStep)
        startupStepName = try c.decodeIfPresent(String.self, forKey: .startupStepName)
        startupStepStatus = try c.decodeIfPresent(StartupStepStatus.self, forKey: .startupStepStatus)
        bootstrap = try c.decodeIfPresent(BootstrapState.self, forKey: .bootstrap) ?? BootstrapState()
        runtimeHostPid = try c.decodeIfPresent(Int32.self, forKey: .runtimeHostPid)
        runtimeControlSocket = try c.decodeIfPresent(String.self, forKey: .runtimeControlSocket)
        initChannel = try c.decodeIfPresent(InitChannelState.self, forKey: .initChannel)
        runtimeUser = try c.decodeIfPresent(RuntimeUserState.self, forKey: .runtimeUser)
        lastErrorCode = try c.decodeIfPresent(String.self, forKey: .lastErrorCode)
        if let message = try c.decodeIfPresent(String.self, forKey: .lastErrorMessage) {
            lastErrorMessage = message
        } else {
            lastErrorMessage = try c.decodeIfPresent(String.self, forKey: .lastError)
        }
        daemonHostPid = try c.decodeIfPresent(Int32.self, forKey: .daemonHostPid)
        daemonControlSocket = try c.decodeIfPresent(String.self, forKey: .daemonControlSocket)
        daemonEventSocket = try c.decodeIfPresent(String.self, forKey: .daemonEventSocket)
        instances = try c.decodeIfPresent([RuntimeInstanceState].self, forKey: .instances)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(distro, forKey: .distro)
        try c.encode(vmState, forKey: .vmState)
        try c.encode(lifecycleState, forKey: .lifecycleState)
        try c.encode(activeSessionCount, forKey: .activeSessionCount)
        try c.encode(idleTimer, forKey: .idleTimer)
        try c.encode(lastTransitionEpochMs, forKey: .lastTransitionEpochMs)
        try c.encodeIfPresent(startupEpochMs, forKey: .startupEpochMs)
        try c.encodeIfPresent(startupStep, forKey: .startupStep)
        try c.encodeIfPresent(startupStepName, forKey: .startupStepName)
        try c.encodeIfPresent(startupStepStatus, forKey: .startupStepStatus)
        try c.encode(bootstrap, forKey: .bootstrap)
        try c.encodeIfPresent(runtimeHostPid, forKey: .runtimeHostPid)
        try c.encodeIfPresent(runtimeControlSocket, forKey: .runtimeControlSocket)
        try c.encodeIfPresent(initChannel, forKey: .initChannel)
        try c.encodeIfPresent(runtimeUser, forKey: .runtimeUser)
        try c.encodeIfPresent(lastErrorCode, forKey: .lastErrorCode)
        try c.encodeIfPresent(lastErrorMessage, forKey: .lastErrorMessage)
        try c.encodeIfPresent(lastErrorMessage, forKey: .lastError)
        try c.encodeIfPresent(daemonHostPid, forKey: .daemonHostPid)
        try c.encodeIfPresent(daemonControlSocket, forKey: .daemonControlSocket)
        try c.encodeIfPresent(daemonEventSocket, forKey: .daemonEventSocket)
        try c.encodeIfPresent(instances, forKey: .instances)
    }
}

public struct RuntimeInstanceState: Codable {
    public var instance: String
    public var vmState: VMState
    public var lifecycleState: RuntimeLifecycleState
    public var activeSessionCount: Int
    public var idleTimer: IdleTimerState
    public var runtimeUser: RuntimeUserState?
    public var initChannel: InitChannelState?
    public var runtimeHostPid: Int32?
    public var runtimeControlSocket: String?
    public var lastError: String?
    public var lastErrorCode: String?
    public var lastErrorMessage: String?
    public var startupEpochMs: Int64?
    public var startupStep: Int?
    public var startupStepName: String?
    public var startupStepStatus: StartupStepStatus?
    public var lastTransitionEpochMs: Int64

    enum CodingKeys: String, CodingKey {
        case instance, vmState, lifecycleState, activeSessionCount, idleTimer, runtimeUser, initChannel
        case runtimeHostPid, runtimeControlSocket, lastError, lastErrorCode, lastErrorMessage
        case startupEpochMs, startupStep, startupStepName, startupStepStatus, lastTransitionEpochMs
    }

    public init(
        instance: String,
        vmState: VMState,
        lifecycleState: RuntimeLifecycleState? = nil,
        activeSessionCount: Int,
        idleTimer: IdleTimerState,
        runtimeUser: RuntimeUserState?,
        initChannel: InitChannelState?,
        runtimeHostPid: Int32?,
        runtimeControlSocket: String?,
        lastError: String? = nil,
        lastErrorCode: String? = nil,
        lastErrorMessage: String? = nil,
        startupEpochMs: Int64? = nil,
        startupStep: Int? = nil,
        startupStepName: String? = nil,
        startupStepStatus: StartupStepStatus? = nil,
        lastTransitionEpochMs: Int64
    ) {
        self.instance = instance
        self.vmState = vmState
        self.lifecycleState = lifecycleState ?? (vmState == .running ? .running : .stopped)
        self.activeSessionCount = activeSessionCount
        self.idleTimer = idleTimer
        self.runtimeUser = runtimeUser
        self.initChannel = initChannel
        self.runtimeHostPid = runtimeHostPid
        self.runtimeControlSocket = runtimeControlSocket
        self.lastError = lastError
        self.lastErrorCode = lastErrorCode
        self.lastErrorMessage = lastErrorMessage
        self.startupEpochMs = startupEpochMs
        self.startupStep = startupStep
        self.startupStepName = startupStepName
        self.startupStepStatus = startupStepStatus
        self.lastTransitionEpochMs = lastTransitionEpochMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        instance = try c.decode(String.self, forKey: .instance)
        vmState = try c.decodeIfPresent(VMState.self, forKey: .vmState) ?? .stopped
        lifecycleState = try c.decodeIfPresent(RuntimeLifecycleState.self, forKey: .lifecycleState)
            ?? (vmState == .running ? .running : .stopped)
        activeSessionCount = try c.decodeIfPresent(Int.self, forKey: .activeSessionCount) ?? 0
        idleTimer = try c.decodeIfPresent(IdleTimerState.self, forKey: .idleTimer) ?? IdleTimerState()
        runtimeUser = try c.decodeIfPresent(RuntimeUserState.self, forKey: .runtimeUser)
        initChannel = try c.decodeIfPresent(InitChannelState.self, forKey: .initChannel)
        runtimeHostPid = try c.decodeIfPresent(Int32.self, forKey: .runtimeHostPid)
        runtimeControlSocket = try c.decodeIfPresent(String.self, forKey: .runtimeControlSocket)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        lastErrorCode = try c.decodeIfPresent(String.self, forKey: .lastErrorCode)
        lastErrorMessage = try c.decodeIfPresent(String.self, forKey: .lastErrorMessage) ?? lastError
        startupEpochMs = try c.decodeIfPresent(Int64.self, forKey: .startupEpochMs)
        startupStep = try c.decodeIfPresent(Int.self, forKey: .startupStep)
        startupStepName = try c.decodeIfPresent(String.self, forKey: .startupStepName)
        startupStepStatus = try c.decodeIfPresent(StartupStepStatus.self, forKey: .startupStepStatus)
        lastTransitionEpochMs = try c.decodeIfPresent(Int64.self, forKey: .lastTransitionEpochMs) ?? nowEpochMs()
    }
}

public struct RuntimeUserState: Codable {
    public var name: String
    public var uid: Int
    public var gid: Int
    public var home: String
    public var shell: String
    public var policyTemplateID: String
    public var lastConvergedEpochMs: Int64
}

public enum InitChannelHealth: String, Codable {
    case ok
    case degraded
    case failed
}

public struct InitChannelState: Codable {
    public var version: Int?
    public var lastHeartbeatEpochMs: Int64?
    public var lastStatus: InitChannelHealth
    public var lastErrorCode: String?
    public var lastErrorMessage: String?

    public init(
        version: Int? = nil,
        lastHeartbeatEpochMs: Int64? = nil,
        lastStatus: InitChannelHealth = .degraded,
        lastErrorCode: String? = nil,
        lastErrorMessage: String? = nil
    ) {
        self.version = version
        self.lastHeartbeatEpochMs = lastHeartbeatEpochMs
        self.lastStatus = lastStatus
        self.lastErrorCode = lastErrorCode
        self.lastErrorMessage = lastErrorMessage
    }
}

public struct SessionEntry: Codable {
    public var id: String
    public var instance: String
    public var logPath: String?
    public var pid: Int32
    public var startedAtEpochMs: Int64

    public init(
        id: String,
        instance: String = "default",
        logPath: String? = nil,
        pid: Int32,
        startedAtEpochMs: Int64
    ) {
        self.id = id
        self.instance = instance
        self.logPath = logPath
        self.pid = pid
        self.startedAtEpochMs = startedAtEpochMs
    }

    enum CodingKeys: String, CodingKey {
        case id
        case instance
        case logPath
        case pid
        case startedAtEpochMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        instance = try c.decodeIfPresent(String.self, forKey: .instance) ?? "default"
        logPath = try c.decodeIfPresent(String.self, forKey: .logPath)
        pid = try c.decode(Int32.self, forKey: .pid)
        startedAtEpochMs = try c.decode(Int64.self, forKey: .startedAtEpochMs)
    }
}

public struct RuntimeBootProfile {
    public var instanceName: String
    public var kernelID: String
    public var kernelURL: URL
    public var commandLine: String
    public var initMode: String
    public var serviceManager: String?
    public var profileSource: String
}

public enum BootstrapContext {
    case runtime
    case install
    case build
}

public struct PortMapping: Codable, Equatable {
    public var instance: String
    public var hostPort: Int
    public var guestPort: Int
    public var bindAddress: String
    public var source: String
    public var createdAtEpochMs: Int64

    public init(
        hostPort: Int,
        guestPort: Int,
        bindAddress: String = "127.0.0.1",
        createdAtEpochMs: Int64 = nowEpochMs(),
        instance: String = "default",
        source: String = "manual"
    ) {
        self.instance = instance
        self.hostPort = hostPort
        self.guestPort = guestPort
        self.bindAddress = bindAddress
        self.source = source
        self.createdAtEpochMs = createdAtEpochMs
    }

    enum CodingKeys: String, CodingKey {
        case instance
        case hostPort
        case guestPort
        case bindAddress
        case source
        case createdAtEpochMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        instance = try c.decodeIfPresent(String.self, forKey: .instance) ?? "default"
        hostPort = try c.decode(Int.self, forKey: .hostPort)
        guestPort = try c.decode(Int.self, forKey: .guestPort)
        bindAddress = try c.decodeIfPresent(String.self, forKey: .bindAddress) ?? "127.0.0.1"
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "manual"
        createdAtEpochMs = try c.decodeIfPresent(Int64.self, forKey: .createdAtEpochMs) ?? nowEpochMs()
    }
}

public struct PortMappingsState: Codable {
    public var schemaVersion: Int
    public var mappings: [PortMapping]

    public init(schemaVersion: Int = 2, mappings: [PortMapping] = []) {
        self.schemaVersion = schemaVersion
        self.mappings = mappings
    }
}

public struct MSLConfig: Codable, Equatable {
    public struct NetworkDNSConfig: Codable, Equatable {
        public var mode: String?
        public var manualNameservers: [String]?
        public var manualSearchDomains: [String]?

        public init(
            mode: String? = nil,
            manualNameservers: [String]? = nil,
            manualSearchDomains: [String]? = nil
        ) {
            self.mode = mode
            self.manualNameservers = manualNameservers
            self.manualSearchDomains = manualSearchDomains
        }
    }

    public struct NetworkConfig: Codable, Equatable {
        public var mode: String?
        public var dns: NetworkDNSConfig?

        public init(mode: String? = nil, dns: NetworkDNSConfig? = nil) {
            self.mode = mode
            self.dns = dns
        }
    }

    public var schemaVersion: Int?
    public var defaultInstanceName: String?
    public var defaultKernelProfileRef: String?
    public var workspaceHostShareRoot: String?
    public var storageCacheToggles: [String: Bool]?
    public var network: NetworkConfig?
    public var memory: MemoryPolicyConfig?

    public init(
        schemaVersion: Int? = 1,
        defaultInstanceName: String? = nil,
        defaultKernelProfileRef: String? = nil,
        workspaceHostShareRoot: String? = nil,
        storageCacheToggles: [String: Bool]? = nil,
        network: NetworkConfig? = nil,
        memory: MemoryPolicyConfig? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.defaultInstanceName = defaultInstanceName
        self.defaultKernelProfileRef = defaultKernelProfileRef
        self.workspaceHostShareRoot = workspaceHostShareRoot
        self.storageCacheToggles = storageCacheToggles
        self.network = network
        self.memory = memory
    }
}

public struct CacheSharingConfig: Codable, Equatable {
    public var enabled: Bool?
    public var apt: Bool?
    public var apk: Bool?
    public var zypper: Bool?
    public var dnf: Bool?
    public var go: Bool?
    public var python: Bool?
    public var npm: Bool?
    public var pnpm: Bool?
    public var yarn: Bool?
    public var maven: Bool?
    public var gradle: Bool?
    public var composer: Bool?
    public var scala: Bool?
    public var ruby: Bool?
    public var rust: Bool?
    public var deno: Bool?
    public var bun: Bool?
    public var nuget: Bool?

    public init(
        enabled: Bool? = nil,
        apt: Bool? = nil,
        apk: Bool? = nil,
        zypper: Bool? = nil,
        dnf: Bool? = nil,
        go: Bool? = nil,
        python: Bool? = nil,
        npm: Bool? = nil,
        pnpm: Bool? = nil,
        yarn: Bool? = nil,
        maven: Bool? = nil,
        gradle: Bool? = nil,
        composer: Bool? = nil,
        scala: Bool? = nil,
        ruby: Bool? = nil,
        rust: Bool? = nil,
        deno: Bool? = nil,
        bun: Bool? = nil,
        nuget: Bool? = nil
    ) {
        self.enabled = enabled
        self.apt = apt
        self.apk = apk
        self.zypper = zypper
        self.dnf = dnf
        self.go = go
        self.python = python
        self.npm = npm
        self.pnpm = pnpm
        self.yarn = yarn
        self.maven = maven
        self.gradle = gradle
        self.composer = composer
        self.scala = scala
        self.ruby = ruby
        self.rust = rust
        self.deno = deno
        self.bun = bun
        self.nuget = nuget
    }
}

public struct MemoryPolicyConfig: Codable, Equatable {
    public var shortIdle: String?
    public var longIdle: String?
    public var hostPressure: String?
    public var cacheCleanThresholdMB: Int?
    public var cooldownDurationS: Int?
    public var hysteresisPercent: Int?

    public init(
        shortIdle: String? = nil,
        longIdle: String? = nil,
        hostPressure: String? = nil,
        cacheCleanThresholdMB: Int? = nil,
        cooldownDurationS: Int? = nil,
        hysteresisPercent: Int? = nil
    ) {
        self.shortIdle = shortIdle
        self.longIdle = longIdle
        self.hostPressure = hostPressure
        self.cacheCleanThresholdMB = cacheCleanThresholdMB
        self.cooldownDurationS = cooldownDurationS
        self.hysteresisPercent = hysteresisPercent
    }
}
