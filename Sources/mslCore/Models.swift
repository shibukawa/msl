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

    public static func initial(nowMs: Int64) -> RuntimeState {
        RuntimeState(
            schemaVersion: 1,
            distro: "default",
            vmState: .stopped,
            activeSessionCount: 0,
            idleTimer: IdleTimerState(),
            lastTransitionEpochMs: nowMs,
            bootstrap: BootstrapState(),
            runtimeHostPid: nil,
            runtimeControlSocket: nil,
            initChannel: nil,
            runtimeUser: nil
        )
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
    public var pid: Int32
    public var startedAtEpochMs: Int64

    public init(id: String, pid: Int32, startedAtEpochMs: Int64) {
        self.id = id
        self.pid = pid
        self.startedAtEpochMs = startedAtEpochMs
    }
}

public struct RuntimeBootProfile {
    public var instanceName: String
    public var kernelID: String
    public var kernelURL: URL
    public var commandLine: String
}

public enum BootstrapContext {
    case runtime
    case install
    case build
}

public struct PortMapping: Codable, Equatable {
    public var hostPort: Int
    public var guestPort: Int
    public var bindAddress: String
    public var createdAtEpochMs: Int64

    public init(hostPort: Int, guestPort: Int, bindAddress: String = "127.0.0.1", createdAtEpochMs: Int64 = nowEpochMs()) {
        self.hostPort = hostPort
        self.guestPort = guestPort
        self.bindAddress = bindAddress
        self.createdAtEpochMs = createdAtEpochMs
    }
}

public struct PortMappingsState: Codable {
    public var schemaVersion: Int
    public var mappings: [PortMapping]

    public init(schemaVersion: Int = 1, mappings: [PortMapping] = []) {
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
