import Foundation

public enum VMState: String, Codable {
    case stopped = "Stopped"
    case running = "Running"
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
    public var activeSessionCount: Int
    public var idleTimer: IdleTimerState
    public var lastTransitionEpochMs: Int64
    public var bootstrap: BootstrapState
    public var runtimeHostPid: Int32?
    public var runtimeControlSocket: String?
    public var initChannel: InitChannelState?
    public var runtimeUser: RuntimeUserState?
    // Step24 schema v2 fields (legacy fields stay for compatibility during migration).
    public var daemonHostPid: Int32?
    public var daemonControlSocket: String?
    public var daemonEventSocket: String?
    public var instances: [RuntimeInstanceState]?

    public static func initial(nowMs: Int64) -> RuntimeState {
        RuntimeState(
            schemaVersion: 2,
            distro: "default",
            vmState: .stopped,
            activeSessionCount: 0,
            idleTimer: IdleTimerState(),
            lastTransitionEpochMs: nowMs,
            bootstrap: BootstrapState(),
            runtimeHostPid: nil,
            runtimeControlSocket: nil,
            initChannel: nil,
            runtimeUser: nil,
            daemonHostPid: nil,
            daemonControlSocket: nil,
            daemonEventSocket: nil,
            instances: [
                RuntimeInstanceState(
                    instance: "default",
                    vmState: .stopped,
                    activeSessionCount: 0,
                    idleTimer: IdleTimerState(),
                    runtimeUser: nil,
                    initChannel: nil,
                    runtimeHostPid: nil,
                    runtimeControlSocket: nil,
                    lastError: nil,
                    lastTransitionEpochMs: nowMs
                )
            ]
        )
    }

    @discardableResult
    public mutating func normalizeSchemaV2(nowMs: Int64) -> Bool {
        var changed = false
        if schemaVersion < 2 {
            schemaVersion = 2
            changed = true
        }
        if instances == nil || instances?.isEmpty == true {
            instances = [
                RuntimeInstanceState(
                    instance: distro,
                    vmState: vmState,
                    activeSessionCount: activeSessionCount,
                    idleTimer: idleTimer,
                    runtimeUser: runtimeUser,
                    initChannel: initChannel,
                    runtimeHostPid: runtimeHostPid,
                    runtimeControlSocket: runtimeControlSocket,
                    lastError: nil,
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
                activeSessionCount: activeSessionCount,
                idleTimer: idleTimer,
                runtimeUser: runtimeUser,
                initChannel: initChannel,
                runtimeHostPid: runtimeHostPid,
                runtimeControlSocket: runtimeControlSocket,
                lastError: merged[distro]?.lastError,
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
                        || lhs.runtimeControlSocket != rhs.runtimeControlSocket {
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
        return changed
    }
}

public struct RuntimeInstanceState: Codable {
    public var instance: String
    public var vmState: VMState
    public var activeSessionCount: Int
    public var idleTimer: IdleTimerState
    public var runtimeUser: RuntimeUserState?
    public var initChannel: InitChannelState?
    public var runtimeHostPid: Int32?
    public var runtimeControlSocket: String?
    public var lastError: String?
    public var lastTransitionEpochMs: Int64
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
        public var dns: NetworkDNSConfig?

        public init(dns: NetworkDNSConfig? = nil) {
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
