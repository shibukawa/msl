import Foundation

public enum DistributionSupportState: String, Codable {
    case supported
    case eol
}

public struct SudoPolicyTemplate: Codable, Equatable {
    public var enabled: Bool
    public var requireSudoBinary: Bool
    public var dropInPath: String
    public var passwordless: Bool?

    public init(
        enabled: Bool = true,
        requireSudoBinary: Bool = false,
        dropInPath: String = "/etc/sudoers.d/msl-user",
        passwordless: Bool? = nil
    ) {
        self.enabled = enabled
        self.requireSudoBinary = requireSudoBinary
        self.dropInPath = dropInPath
        self.passwordless = passwordless
    }
}

public struct SuPolicyTemplate: Codable, Equatable {
    public var enabled: Bool
    public var passwordless: Bool?

    public init(
        enabled: Bool = false,
        passwordless: Bool? = nil
    ) {
        self.enabled = enabled
        self.passwordless = passwordless
    }
}

public struct WelcomePolicyTemplate: Codable, Equatable {
    public var enabled: Bool
    public var frequency: String
    public var respectHushlogin: Bool

    public init(
        enabled: Bool = true,
        frequency: String = "daily",
        respectHushlogin: Bool = true
    ) {
        self.enabled = enabled
        self.frequency = frequency
        self.respectHushlogin = respectHushlogin
    }
}

public struct UserConvergencePolicyTemplate: Codable, Equatable {
    public var templateId: String
    public var commandFamily: String
    public var adminGroup: String
    public var sudoPolicy: SudoPolicyTemplate
    public var suPolicy: SuPolicyTemplate?
    public var shellFallbacks: [String]
    public var welcomePolicy: WelcomePolicyTemplate
    public var editable: Bool?

    public init(
        templateId: String,
        commandFamily: String,
        adminGroup: String,
        sudoPolicy: SudoPolicyTemplate,
        suPolicy: SuPolicyTemplate? = nil,
        shellFallbacks: [String],
        welcomePolicy: WelcomePolicyTemplate,
        editable: Bool? = nil
    ) {
        self.templateId = templateId
        self.commandFamily = commandFamily
        self.adminGroup = adminGroup
        self.sudoPolicy = sudoPolicy
        self.suPolicy = suPolicy
        self.shellFallbacks = shellFallbacks
        self.welcomePolicy = welcomePolicy
        self.editable = editable
    }
}

public typealias UserConvergencePolicy = UserConvergencePolicyTemplate

public struct DistributionManifestEntry: Codable, Equatable {
    public var id: String
    public var distro: String
    public var version: String
    public var arch: String
    public var tarballURL: String
    public var sha256: String
    public var signatureURL: String?
    public var checksumURL: String?
    public var signatureTarget: String?
    public var keyFingerprint: String?
    public var supportState: DistributionSupportState
    public var serviceManager: String?
    public var defaultInitMode: String?
    public var userConvergenceTemplate: UserConvergencePolicyTemplate?
    public var cacheSharingDefaults: CacheSharingConfig?

    public init(
        id: String,
        distro: String,
        version: String,
        arch: String,
        tarballURL: String,
        sha256: String,
        signatureURL: String?,
        checksumURL: String?,
        signatureTarget: String?,
        keyFingerprint: String?,
        supportState: DistributionSupportState,
        serviceManager: String? = nil,
        defaultInitMode: String? = nil,
        userConvergenceTemplate: UserConvergencePolicyTemplate? = nil,
        cacheSharingDefaults: CacheSharingConfig? = nil
    ) {
        self.id = id
        self.distro = distro
        self.version = version
        self.arch = arch
        self.tarballURL = tarballURL
        self.sha256 = sha256
        self.signatureURL = signatureURL
        self.checksumURL = checksumURL
        self.signatureTarget = signatureTarget
        self.keyFingerprint = keyFingerprint
        self.supportState = supportState
        self.serviceManager = serviceManager
        self.defaultInitMode = defaultInitMode
        self.userConvergenceTemplate = userConvergenceTemplate
        self.cacheSharingDefaults = cacheSharingDefaults
    }
}

public struct DistributionInstallDescriptor: Codable, Equatable {
    public var canonicalName: String
    public var aliases: [String]
    public var manifestId: String

    public init(canonicalName: String, aliases: [String], manifestId: String) {
        self.canonicalName = canonicalName
        self.aliases = aliases
        self.manifestId = manifestId
    }
}

public struct InstalledInstanceDescriptor: Codable, Equatable {
    public var name: String
    public var hasDisk: Bool
    public var createdAtEpochMs: Int64?

    public init(name: String, hasDisk: Bool, createdAtEpochMs: Int64?) {
        self.name = name
        self.hasDisk = hasDisk
        self.createdAtEpochMs = createdAtEpochMs
    }
}

public struct DistributionUninstallResult: Codable, Equatable {
    public var name: String
    public var removedInstancePath: String
    public var removedCachePath: String?
    public var keptCachePath: String?

    public init(
        name: String,
        removedInstancePath: String,
        removedCachePath: String?,
        keptCachePath: String?
    ) {
        self.name = name
        self.removedInstancePath = removedInstancePath
        self.removedCachePath = removedCachePath
        self.keptCachePath = keptCachePath
    }
}

public struct DistributionSourceRecord: Codable, Equatable {
    public var sourceType: String
    public var distro: String?
    public var version: String?
    public var arch: String?
    public var manifestId: String?
    public var localPath: String?
    public var tarballFileName: String
    public var sha256: String
    public var verifiedAtEpochMs: Int64
}

public struct WorkspacePolicy: Codable, Equatable {
    public var activationMode: String
    public var startupMountEnabled: Bool
    public var protectedGuestPathPrefixes: [String]?

    public init(
        activationMode: String = "mslconfig_presence_only",
        startupMountEnabled: Bool = true,
        protectedGuestPathPrefixes: [String]? = nil
    ) {
        self.activationMode = activationMode
        self.startupMountEnabled = startupMountEnabled
        self.protectedGuestPathPrefixes = protectedGuestPathPrefixes
    }
}

public struct DistributionCompressionPolicy: Codable, Equatable {
    public var pathPolicies: [CompressionPathPolicyEntry]
    public var cacheToggles: [String: Bool]
    public var catalogPath: String
    public var resolvedAtEpochMs: Int64

    public init(
        pathPolicies: [CompressionPathPolicyEntry],
        cacheToggles: [String: Bool],
        catalogPath: String,
        resolvedAtEpochMs: Int64
    ) {
        self.pathPolicies = pathPolicies
        self.cacheToggles = cacheToggles
        self.catalogPath = catalogPath
        self.resolvedAtEpochMs = resolvedAtEpochMs
    }
}

public struct DistributionNetworkDNSPolicy: Codable, Equatable {
    public var mode: String?
    public var resolverBackend: String?
    public var manualNameservers: [String]?
    public var manualSearchDomains: [String]?

    public init(
        mode: String? = nil,
        resolverBackend: String? = nil,
        manualNameservers: [String]? = nil,
        manualSearchDomains: [String]? = nil
    ) {
        self.mode = mode
        self.resolverBackend = resolverBackend
        self.manualNameservers = manualNameservers
        self.manualSearchDomains = manualSearchDomains
    }
}

public struct DistributionNetworkPolicy: Codable, Equatable {
    public var dns: DistributionNetworkDNSPolicy?

    public init(dns: DistributionNetworkDNSPolicy? = nil) {
        self.dns = dns
    }
}

public struct DistributionInstanceMetadata: Codable, Equatable {
    public struct TmpStoragePolicy: Codable, Equatable {
        public var mode: String
        public var sizeMiB: Int
        public var resetOnStop: Bool

        public init(
            mode: String = "embedded",
            sizeMiB: Int = 1024,
            resetOnStop: Bool = true
        ) {
            self.mode = mode
            self.sizeMiB = sizeMiB
            self.resetOnStop = resetOnStop
        }
    }

    public struct ImageMaintenanceStatus: Codable, Equatable {
        public var lastRunAtEpochMs: Int64?
        public var lastOperation: String?
        public var lastResult: String?
        public var lastErrorCode: String?
        public var lastErrorMessage: String?
        public var lastCompactAtEpochMs: Int64?
        public var lastCompactBytesBefore: Int64?
        public var lastCompactBytesAfter: Int64?
        public var lastRefreshVersionBefore: String?
        public var lastRefreshVersionAfter: String?
        public var cachedTotalContentBytes: Int64?
        public var cachedCompressedBytes: Int64?
        public var cachedCompressionSavingPercent: Double?
        public var cachedAtEpochMs: Int64?

        public init(
            lastRunAtEpochMs: Int64? = nil,
            lastOperation: String? = nil,
            lastResult: String? = nil,
            lastErrorCode: String? = nil,
            lastErrorMessage: String? = nil,
            lastCompactAtEpochMs: Int64? = nil,
            lastCompactBytesBefore: Int64? = nil,
            lastCompactBytesAfter: Int64? = nil,
            lastRefreshVersionBefore: String? = nil,
            lastRefreshVersionAfter: String? = nil,
            cachedTotalContentBytes: Int64? = nil,
            cachedCompressedBytes: Int64? = nil,
            cachedCompressionSavingPercent: Double? = nil,
            cachedAtEpochMs: Int64? = nil
        ) {
            self.lastRunAtEpochMs = lastRunAtEpochMs
            self.lastOperation = lastOperation
            self.lastResult = lastResult
            self.lastErrorCode = lastErrorCode
            self.lastErrorMessage = lastErrorMessage
            self.lastCompactAtEpochMs = lastCompactAtEpochMs
            self.lastCompactBytesBefore = lastCompactBytesBefore
            self.lastCompactBytesAfter = lastCompactBytesAfter
            self.lastRefreshVersionBefore = lastRefreshVersionBefore
            self.lastRefreshVersionAfter = lastRefreshVersionAfter
            self.cachedTotalContentBytes = cachedTotalContentBytes
            self.cachedCompressedBytes = cachedCompressedBytes
            self.cachedCompressionSavingPercent = cachedCompressionSavingPercent
            self.cachedAtEpochMs = cachedAtEpochMs
        }
    }
    public struct RuntimeInitProfile: Codable, Equatable {
        public var initMode: String
        public var serviceManager: String

        public init(initMode: String, serviceManager: String) {
            self.initMode = initMode
            self.serviceManager = serviceManager
        }
    }

    public struct PrivilegeBootstrap: Codable, Equatable {
        public var firstBootPending: Bool
        public var privilegeBootstrapVersion: Int
        public var lastResult: String
        public var lastBootstrapAtEpochMs: Int64?

        public init(
            firstBootPending: Bool = true,
            privilegeBootstrapVersion: Int = 1,
            lastResult: String = "pending",
            lastBootstrapAtEpochMs: Int64? = nil
        ) {
            self.firstBootPending = firstBootPending
            self.privilegeBootstrapVersion = privilegeBootstrapVersion
            self.lastResult = lastResult
            self.lastBootstrapAtEpochMs = lastBootstrapAtEpochMs
        }
    }

    public struct UserSnapshot: Codable, Equatable {
        public var name: String
        public var uid: Int
        public var gid: Int
        public var groups: [String]

        public init(name: String, uid: Int, gid: Int, groups: [String]) {
            self.name = name
            self.uid = uid
            self.gid = gid
            self.groups = groups
        }
    }

    public var name: String
    public var distroFamily: String?
    public var createdAtEpochMs: Int64
    public var bootstrap: PrivilegeBootstrap?
    public var user: UserSnapshot?
    public var source: DistributionSourceRecord
    public var diskPath: String
    public var kernelProfileRef: String?
    public var runtimeProfile: RuntimeInitProfile?
    public var userConvergencePolicy: UserConvergencePolicy?
    public var workspacePolicy: WorkspacePolicy?
    public var compressionPolicy: DistributionCompressionPolicy?
    public var networkPolicy: DistributionNetworkPolicy?
    public var cacheSharing: CacheSharingConfig?
    public var imageMaintenance: ImageMaintenanceStatus?
    public var tmpStorage: TmpStoragePolicy?

    public init(
        name: String,
        distroFamily: String? = nil,
        createdAtEpochMs: Int64,
        bootstrap: PrivilegeBootstrap? = nil,
        user: UserSnapshot? = nil,
        source: DistributionSourceRecord,
        diskPath: String,
        kernelProfileRef: String?,
        runtimeProfile: RuntimeInitProfile? = nil,
        userConvergencePolicy: UserConvergencePolicy?,
        workspacePolicy: WorkspacePolicy? = nil,
        compressionPolicy: DistributionCompressionPolicy? = nil,
        networkPolicy: DistributionNetworkPolicy? = nil,
        cacheSharing: CacheSharingConfig? = nil,
        imageMaintenance: ImageMaintenanceStatus? = nil,
        tmpStorage: TmpStoragePolicy? = nil
    ) {
        self.name = name
        self.distroFamily = distroFamily
        self.createdAtEpochMs = createdAtEpochMs
        self.bootstrap = bootstrap
        self.user = user
        self.source = source
        self.diskPath = diskPath
        self.kernelProfileRef = kernelProfileRef
        self.runtimeProfile = runtimeProfile
        self.userConvergencePolicy = userConvergencePolicy
        self.workspacePolicy = workspacePolicy
        self.compressionPolicy = compressionPolicy
        self.networkPolicy = networkPolicy
        self.cacheSharing = cacheSharing
        self.imageMaintenance = imageMaintenance
        self.tmpStorage = tmpStorage
    }

    public static func defaultTmpStoragePolicyForNewInstance() -> TmpStoragePolicy {
        TmpStoragePolicy(mode: "ephemeral", sizeMiB: 1024, resetOnStop: true)
    }

    public static func defaultTmpStoragePolicy(forNewInstanceNamed name: String) -> TmpStoragePolicy {
        let _ = name
        return defaultTmpStoragePolicyForNewInstance()
    }

    public static func defaultTmpStoragePolicyForExistingInstance() -> TmpStoragePolicy {
        TmpStoragePolicy(mode: "embedded", sizeMiB: 1024, resetOnStop: true)
    }

    public func resolveValidatedTmpStoragePolicy(applyEnvironmentOverride: Bool = true) throws -> TmpStoragePolicy {
        if applyEnvironmentOverride && Self.isForceEmbeddedEnabled() {
            return Self.defaultTmpStoragePolicyForExistingInstance()
        }
        let raw = tmpStorage ?? Self.defaultTmpStoragePolicyForExistingInstance()
        let normalizedMode = raw.mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedMode == "embedded" || normalizedMode == "ephemeral" else {
            throw MSLRuntimeError(
                "invalid tmpStorage.mode '\(raw.mode)' for instance '\(name)': allowed=[embedded,ephemeral]"
            )
        }
        guard raw.sizeMiB > 0 else {
            throw MSLRuntimeError(
                "invalid tmpStorage.sizeMiB '\(raw.sizeMiB)' for instance '\(name)': must be > 0"
            )
        }
        return TmpStoragePolicy(
            mode: normalizedMode,
            sizeMiB: raw.sizeMiB,
            resetOnStop: raw.resetOnStop
        )
    }

    private static func isForceEmbeddedEnabled() -> Bool {
        let raw = ProcessInfo.processInfo.environment["MSL_TMP_STORAGE_FORCE_EMBEDDED"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return raw == "1" || raw == "true" || raw == "yes"
    }
}

public struct DistributionVerifiedRecord: Codable, Equatable {
    public var tarballPath: String
    public var sha256: String
    public var signatureFingerprint: String?
    public var verifiedAtEpochMs: Int64
    public var manifestId: String?
}

enum DistributionSourceSelection {
    case manifest(DistributionManifestEntry)
    case localFile(URL)
}
