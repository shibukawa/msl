import Foundation
import Darwin

/// Process-wide SIGINT flag. Set by C signal handler, checked by wait loops.
private var mslInterrupted: Bool = false
private func mslSigintHandler(_: Int32) {
    mslInterrupted = true
}

/// Install SIGINT handler that sets the flag instead of terminating.
func installInterruptHandler() {
    mslInterrupted = false
    signal(SIGINT, mslSigintHandler)
}

/// Check if SIGINT has been received.
func isInterrupted() -> Bool {
    return mslInterrupted
}

public final class RuntimeManager {
    private enum NerdctlTerminalMode {
        case streamingProc
        case displayPTY
        case interactivePTY

        var transport: String {
            switch self {
            case .streamingProc:
                return "direct_init_proc_stream"
            case .displayPTY:
                return "direct_init_display_pty"
            case .interactivePTY:
                return "direct_init_interactive_pty"
            }
        }
    }

    private struct NerdctlExecutionResult {
        var exitCode: Int32
        var capturedOutput: String
    }

    private final class RollingOutputCapture {
        private let limit: Int
        private var data = Data()

        init(limit: Int = 256 * 1024) {
            self.limit = limit
        }

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            data.append(chunk)
            if data.count > limit {
                data.removeFirst(data.count - limit)
            }
        }

        var stringValue: String {
            String(data: data, encoding: .utf8) ?? ""
        }
    }

    struct ResolvedRunInvocation: Equatable {
        var argv: [String]
        var cwd: String?
        var envAdditions: [String: String]?
        var runAsRoot: Bool
        var startupNotice: String?
    }

    private let paths: MSLPaths
    private let fileManager: FileManager
    private let lock: FileLock
    private let store: StateStore
    private let bootstrap: BootstrapManager
    private let sessions: SessionManager
    private let logger: MSLLogger
    private let executablePath: String
    private let defaultInstanceStore: DefaultInstanceStore
    private let appManagerStateStore: AppManagerStateStore

    private lazy var daemonClient: DaemonClient = {
        DaemonClient(
            paths: paths,
            lock: lock,
            store: store,
            logger: logger,
            executablePath: executablePath
        )
    }()

    private lazy var distributionManager: DistributionManager = {
        DistributionManager(paths: paths, logger: logger)
    }()

    public init(executablePath: String, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        let runtimeRootOverride = ProcessInfo.processInfo.environment["MSL_RUNTIME_ROOT"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        if let homeOverride = ProcessInfo.processInfo.environment["MSL_HOME"], !homeOverride.isEmpty {
            self.paths = MSLPaths(
                homeDirectoryURL: URL(fileURLWithPath: homeOverride),
                runtimeRootURL: runtimeRootOverride
            )
        } else {
            self.paths = MSLPaths(
                homeDirectoryURL: fileManager.homeDirectoryForCurrentUser,
                runtimeRootURL: runtimeRootOverride
            )
        }

        try fileManager.createDirectory(at: paths.runtime, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.appLogs, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.appControl, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.distrosDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.cacheDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.cacheDownloadsDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.cacheStagingDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.kernelsDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.sshDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.sshInstancesDir, withIntermediateDirectories: true)

        self.logger = MSLLogger(logFile: paths.logs.appendingPathComponent("msl.log", isDirectory: false), fileManager: fileManager)
        self.lock = try FileLock(path: paths.lockFile.path)
        self.store = StateStore(paths: paths, fileManager: fileManager)
        self.bootstrap = BootstrapManager(paths: paths, logger: logger, fileManager: fileManager)
        self.sessions = SessionManager(store: store)
        self.executablePath = RuntimeManager.resolveExecutablePath(executablePath, fileManager: fileManager)
        self.defaultInstanceStore = DefaultInstanceStore(paths: paths, fileManager: fileManager)
        self.appManagerStateStore = AppManagerStateStore(paths: paths, fileManager: fileManager)

        do {
            try distributionManager.migrateLegacyRootfsCacheIfNeeded()
        } catch {
            logger.log("cache_layout_migration_failed", fields: [
                "error": String(describing: error)
            ])
        }
    }

    public func runInitWorkspace(
        force: Bool,
        instanceName: String? = nil
    ) throws -> Never {
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            .resolvingSymlinksInPath()
        let sharedRoot = resolveWorkspaceHostShareRoot()

        let result = try WorkspaceConfigInitializer(fileManager: fileManager).createConfig(
            in: cwd,
            force: force
        )
        if result.overwritten {
            print("workspace config updated: \(result.configFile.path)")
        } else {
            print("workspace config created: \(result.configFile.path)")
        }
        for note in result.notes {
            print(note)
        }
        if !WorkspaceHostSharePolicy.isPathAllowed(cwd.path, withinRoot: sharedRoot) {
            print("warning: \(cwd.path) is outside workspace host share root (\(sharedRoot)).")
            print("workspace mirror will fallback to home until you update: \(paths.configFile.path)")
            print("add/adjust `workspaceHostShareRoot` to include this folder (example: \"\(cwd.deletingLastPathComponent().path)\").")
        }
        Foundation.exit(0)
    }

    public func runSSHInfo(instanceName: String? = nil, requestedPort: Int? = nil, format: String = "text") throws -> Never {
        if requestedPort != nil {
            throw MSLRuntimeError("ssh-info no longer accepts runtime port overrides; the desktop manager owns listener ports")
        }
        let target = try resolveRuntimeTarget(explicitInstanceName: instanceName)
        let metadata = try distributionManager.readOrRebuildInstanceMetadata(at: target.metadataURL)
        if metadata.resolvedStartupMode() == .processFirst {
            throw MSLRuntimeError("ssh is not supported for this instance mode")
        }
        guard fileManager.fileExists(atPath: paths.managerSocketFile.path) else {
            throw MSLRuntimeError("MSLDesktop is not running. Start MSLDesktop and retry `msl ssh-info`.")
        }
        let client = ManagerControlClient(socketPath: paths.managerSocketFile.path)
        let response = try client.send(
            ManagerControlRequest(
                op: "ssh_info",
                instance: target.instanceName,
                callerCwd: fileManager.currentDirectoryPath,
                hostShareRoot: resolveWorkspaceHostShareRoot()
            )
        )
        guard response.ok, let info = response.sshInfo ?? response.worker?.sshInfo else {
            throw MSLRuntimeError(response.error ?? "failed to fetch ssh info from MSLDesktop manager")
        }
        switch format.lowercased() {
        case "json":
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(info)
            if let text = String(data: data, encoding: .utf8) {
                print(text)
            }
        case "text":
            print("alias: \(info.alias)")
            print("host: \(info.host)")
            print("port: \(info.port)")
            print("user: \(info.user)")
            print("shared_config: \(info.sharedConfigPath)")
            print("config: \(info.configPath)")
            print("identity: \(info.identityFile)")
            print("known_hosts: \(info.knownHostsFile)")
        default:
            throw MSLRuntimeError("unsupported ssh-info format '\(format)'. use text or json")
        }
        Foundation.exit(0)
    }

    public func runCopy(
        src: String,
        dest: String,
        recursive: Bool,
        instanceName: String? = nil
    ) throws -> Never {
        try runCopyProcess(src: src, dest: dest, recursive: recursive, instanceName: instanceName)
        Foundation.exit(0)
    }

    func runCopyProcess(
        src: String,
        dest: String,
        recursive: Bool,
        instanceName: String? = nil
    ) throws {
        let target = try resolveRuntimeTarget(explicitInstanceName: instanceName)
        let transfer = try MSLCopyPathParser.parseTransfer(
            src: src,
            dest: dest,
            recursive: recursive,
            fileManager: fileManager
        )
        switch (transfer.src, transfer.dest) {
        case (.local(let localPath), .remote(let remotePath)):
            let expandedLocalPath = try expandLocalCopyPath(localPath)
            let localURL = URL(fileURLWithPath: expandedLocalPath)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: localURL.path, isDirectory: &isDirectory) else {
                throw MSLRuntimeError("source '\(localPath)' not found")
            }
            if isDirectory.boolValue {
                guard recursive else {
                    throw MSLRuntimeError("omitting directory '\(localPath)'; use -r to copy directories")
                }
                try copyLocalDirectoryToRemote(localURL: localURL, remotePath: remotePath, instanceName: target.instanceName)
            } else {
                try copyLocalFileToRemote(localURL: localURL, remotePath: remotePath, instanceName: target.instanceName)
            }
        case (.remote(let remotePath), .local(let localPath)):
            if recursive {
                try copyRemoteDirectoryToLocal(remotePath: remotePath, localPath: localPath, instanceName: target.instanceName)
            } else {
                try copyRemoteFileToLocal(remotePath: remotePath, localPath: localPath, instanceName: target.instanceName)
            }
        case (.local, .local), (.remote, .remote):
            throw MSLRuntimeError("msl cp requires exactly one VM path using @:/path")
        }
    }

    public func runSetConfig(path rawPath: String, value rawValue: String) throws -> Never {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)

        let prefix = "storageCacheToggles."
        if path == "network.mode" {
            let mode = value.lowercased()
            guard mode == "auto" || mode == "vmnet" || mode == "nat" else {
                throw MSLRuntimeError("invalid network.mode '\(value)'. supported: auto|vmnet|nat")
            }
            var config = try defaultInstanceStore.loadConfig()
            var network = config.network ?? MSLConfig.NetworkConfig()
            network.mode = mode
            config.network = network
            try defaultInstanceStore.saveConfig(config)
            logger.log("config_network_mode_updated", fields: ["mode": mode])
            print("config updated: network.mode=\(mode)")
            Foundation.exit(0)
        }

        if path == "network.dns.mode" {
            let mode = value.lowercased()
            guard mode == "host" || mode == "manual" || mode == "unmanaged" else {
                throw MSLRuntimeError("invalid network.dns.mode '\(value)'. supported: host|manual|unmanaged")
            }
            var config = try defaultInstanceStore.loadConfig()
            var network = config.network ?? MSLConfig.NetworkConfig()
            var dns = network.dns ?? MSLConfig.NetworkDNSConfig()
            dns.mode = mode
            network.dns = dns
            config.network = network
            try defaultInstanceStore.saveConfig(config)
            logger.log("config_dns_mode_updated", fields: ["mode": mode])
            print("config updated: network.dns.mode=\(mode)")
            Foundation.exit(0)
        }

        if path == "network.dns.manualNameservers" {
            let nameservers = value
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            var config = try defaultInstanceStore.loadConfig()
            var network = config.network ?? MSLConfig.NetworkConfig()
            var dns = network.dns ?? MSLConfig.NetworkDNSConfig()
            dns.manualNameservers = nameservers
            network.dns = dns
            config.network = network
            try defaultInstanceStore.saveConfig(config)
            logger.log("config_dns_nameservers_updated", fields: ["count": String(nameservers.count)])
            print("config updated: network.dns.manualNameservers=\(nameservers.joined(separator: ","))")
            Foundation.exit(0)
        }

        if path == "network.dns.manualSearchDomains" {
            let domains = value
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            var config = try defaultInstanceStore.loadConfig()
            var network = config.network ?? MSLConfig.NetworkConfig()
            var dns = network.dns ?? MSLConfig.NetworkDNSConfig()
            dns.manualSearchDomains = domains
            network.dns = dns
            config.network = network
            try defaultInstanceStore.saveConfig(config)
            logger.log("config_dns_search_domains_updated", fields: ["count": String(domains.count)])
            print("config updated: network.dns.manualSearchDomains=\(domains.joined(separator: ","))")
            Foundation.exit(0)
        }

        guard path.hasPrefix(prefix) else {
            throw MSLRuntimeError(
                "unsupported config key '\(path)'. supported: storageCacheToggles.<name>, network.mode, network.dns.mode, network.dns.manualNameservers, network.dns.manualSearchDomains"
            )
        }

        let name = String(path.dropFirst(prefix.count))
        guard !name.isEmpty else {
            throw MSLRuntimeError("missing cache toggle name. use: storageCacheToggles.<name>")
        }

        let lowered = value.lowercased()
        let enabled: Bool
        if lowered == "true" || lowered == "1" {
            enabled = true
        } else if lowered == "false" || lowered == "0" {
            enabled = false
        } else {
            throw MSLRuntimeError("invalid boolean value '\(value)'. use true|false")
        }

        try defaultInstanceStore.setStorageCacheToggle(name: name, enabled: enabled)
        logger.log("config_storage_cache_toggle_updated", fields: [
            "name": name.lowercased(),
            "enabled": enabled ? "true" : "false"
        ])
        print("config updated: storageCacheToggles.\(name.lowercased())=\(enabled ? "true" : "false")")
        Foundation.exit(0)
    }

    public func runListStorageCacheToggles() throws -> Never {
        let toggles = try defaultInstanceStore.loadStorageCacheToggles()
        for key in toggles.keys.sorted() {
            let value = toggles[key] == true ? "true" : "false"
            print("\(key)=\(value)")
        }
        Foundation.exit(0)
    }

    public func runCacheSharingStatus() throws -> Never {
        let defaultInstanceName = try defaultInstanceStore.loadDefaultInstanceName()
        let metadataURL = try distributionManager.runtimeMetadataURL(defaultInstanceName: defaultInstanceName)
        let metadata = try distributionManager.readOrRebuildInstanceMetadata(at: metadataURL)
        let policyConfig = metadata.cacheSharing ?? CacheSharingPolicyResolver.defaultConfigForDistroFamily(
            metadata.distroFamily
                ?? metadata.source.distro
                ?? DistributionManager.inferDistroFamilyStatic(from: metadata.source.manifestId)
        )
        let source = metadata.cacheSharing == nil ? "metadata_inferred" : "metadata"
        let policy = CacheSharingPolicyResolver.resolve(config: policyConfig)
        let hostHome = ProcessInfo.processInfo.environment["HOME"] ?? fileManager.homeDirectoryForCurrentUser.path
        let hostCacheRoot = CacheSharingPolicyResolver.hostCacheRootPath(hostHome: hostHome)
        let hostShareRoot = resolveWorkspaceHostShareRoot()
        let guestCacheRoot = CacheSharingPolicyResolver.guestPathForHostPath(
            hostPath: hostCacheRoot,
            hostShareRoot: hostShareRoot
        ) ?? "unavailable"

        print("instance=\(metadata.name)")
        print("configSource=\(source)")
        print("enabled=\(policy.enabled ? "true" : "false")")
        print("hostCacheRoot=\(hostCacheRoot)")
        print("hostShareRoot=\(hostShareRoot)")
        print("guestCacheRoot=\(guestCacheRoot)")
        let flags = CacheSharingPolicyResolver.toolFlagList(policy: policy)
        for key in flags.keys.sorted() {
            let value = flags[key] == true ? "true" : "false"
            print("tool.\(key)=\(value)")
            if key == "apt", flags[key] == true {
                print("tool.apt.mode=archives-only")
            }
        }
        Foundation.exit(0)
    }

    public func runCacheFetch(
        targetAlias: String?,
        localFilePath: String?,
        force: Bool
    ) throws -> Never {
        let result = try distributionManager.fetch(
            targetAlias: targetAlias,
            localFilePath: localFilePath,
            force: force
        )
        print("cached: \(result.tarballPath)")
        print("sha256: \(result.sha256)")
        Foundation.exit(0)
    }

    public func runInstall(
        name: String,
        targetAlias: String?,
        localFilePath: String?,
        rawDiskPath: String?,
        containerImageRef: String?,
        containerEntrypointOverride: [String]?,
        rebuild: Bool,
        diskSizeGB: Int?
    ) throws -> Never {
        // Internal bootstrap instance must stay on legacy path to avoid recursion.
        if name == "_imagewriter" {
            try runBootstrapInstall(
                name: name,
                targetAlias: targetAlias,
                localFilePath: localFilePath,
                containerImageRef: containerImageRef,
                rebuild: rebuild,
                diskSizeGB: diskSizeGB
            )
        }

        try bootstrap.ensureBootstrapped(context: .install)

        let dir: URL
        if let rawDiskPath {
            dir = try distributionManager.createImageFromRaw(
                name: name,
                rawDiskPath: rawDiskPath,
                rebuild: rebuild
            )
        } else {
            dir = try distributionManager.createImageWithImagewriter(
                name: name,
                targetAlias: targetAlias,
                localFilePath: localFilePath,
                containerImageRef: containerImageRef,
                containerEntrypointOverride: containerEntrypointOverride,
                rebuild: rebuild,
                diskSizeGB: diskSizeGB,
                mslExecutablePath: executablePath
            )
        }

        try finalizeDefaultInstanceAndKernelIfNeeded(installedName: name)
        print("image created: \(dir.path)")
        Foundation.exit(0)
    }

    public func runBootstrapInstall(
        name: String,
        targetAlias: String?,
        localFilePath: String?,
        containerImageRef _: String? = nil,
        rebuild: Bool,
        diskSizeGB: Int?
    ) throws -> Never {
        try bootstrap.ensureBootstrapped(context: .install)

        let dir = try distributionManager.createImage(
            name: name,
            targetAlias: targetAlias,
            localFilePath: localFilePath,
            rebuild: rebuild,
            diskSizeGB: diskSizeGB
        )

        try finalizeDefaultInstanceAndKernelIfNeeded(installedName: name)
        print("image created: \(dir.path)")
        Foundation.exit(0)
    }

    private func finalizeDefaultInstanceAndKernelIfNeeded(installedName name: String) throws {
        if distributionManager.isReservedInternalInstanceName(name) {
            return
        }
        if try defaultInstanceStore.loadDefaultInstanceName() == nil {
            try defaultInstanceStore.setDefaultInstanceName(name)
            logger.log("default_instance_auto_set", fields: ["name": name])
        }
        let env = ProcessInfo.processInfo.environment
        if let envKernelID = env["MSL_KERNEL_PROFILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !envKernelID.isEmpty {
            let currentKernelRef = try defaultInstanceStore.loadDefaultKernelProfileRef()
            let shouldUpdateKernelRef: Bool
            if let currentKernelRef {
                let currentKernelPath = paths.kernelsDir
                    .appendingPathComponent(currentKernelRef, isDirectory: true)
                    .appendingPathComponent("vmlinuz", isDirectory: false)
                    .path
                shouldUpdateKernelRef = !FileManager.default.fileExists(atPath: currentKernelPath)
            } else {
                shouldUpdateKernelRef = true
            }

            if shouldUpdateKernelRef {
                try defaultInstanceStore.setDefaultKernelProfileRef(envKernelID)
                logger.log("default_kernel_profile_auto_set", fields: ["kernel_id": envKernelID])
            }
        }
    }

    public func runBuildStorageImage(
        profileName: String,
        configPath: String,
        outputPath: String,
        force: Bool
    ) throws -> Never {
        try bootstrap.ensureBootstrapped(context: .build)
        let builder = StorageImageBuildManager(paths: paths, logger: logger, fileManager: fileManager)
        let metadata = try builder.build(
            profileName: profileName,
            configPath: configPath,
            outputPath: outputPath,
            force: force
        )

        print("storage image created: \(outputPath)")
        print("profile: \(metadata.profileName)")
        print("base sha256: \(metadata.baseImageSha256)")
        Foundation.exit(0)
    }

    public func listInstallableDistributions() -> Never {
        let descriptors = distributionManager.installableDistributions()
        if descriptors.isEmpty {
            print("no installable distributions available in embedded manifest")
            Foundation.exit(1)
        }
        for descriptor in descriptors {
            if descriptor.aliases.isEmpty {
                print(descriptor.canonicalName)
            } else {
                let aliases = descriptor.aliases.joined(separator: ", ")
                print("\(descriptor.canonicalName) (aliases: \(aliases))")
            }
        }
        Foundation.exit(0)
    }

    public func listInstalledInstances(includeReserved: Bool = false) throws -> Never {
        let instances = distributionManager
            .installedInstances(includeReserved: includeReserved)
            .filter(\.hasDisk)

        if instances.isEmpty {
            Foundation.exit(0)
        }

        let configuredDefault = try defaultInstanceStore.loadDefaultInstanceName()
        let instanceNames = Set(instances.map(\.name))
        let effectiveDefault: String?
        if let configuredDefault, instanceNames.contains(configuredDefault) {
            effectiveDefault = configuredDefault
        } else {
            effectiveDefault = instances.first(where: { !distributionManager.isReservedInternalInstanceName($0.name) })?.name
        }

        for instance in instances {
            if instance.name == effectiveDefault {
                print("\(instance.name) [default]")
            } else {
                print(instance.name)
            }
        }
        Foundation.exit(0)
    }

    public func setDefaultInstance(name rawName: String) throws -> Never {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw MSLRuntimeError("instance name is required for --set-default")
        }
        guard distributionManager.instanceExists(named: name) else {
            throw MSLRuntimeError("instance '\(name)' not found")
        }

        let previous = try defaultInstanceStore.loadDefaultInstanceName()
        try defaultInstanceStore.setDefaultInstanceName(name)
        logger.log("default_instance_updated", fields: [
            "old": previous ?? "",
            "new": name
        ])
        print("default instance set to \(name)")
        Foundation.exit(0)
    }

    public func runUninstall(name rawName: String, keepCache: Bool) throws -> Never {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw MSLRuntimeError("instance name is required for uninstall")
        }

        let result: DistributionUninstallResult = try lock.withExclusiveLock {
            let state = try store.loadState()
            if state.vmState == .running, state.distro == name {
                throw MSLRuntimeError("instance '\(name)' is running. run `msl stop` first.")
            }

            let uninstallResult = try distributionManager.uninstallInstance(name: name, keepCache: keepCache)

            let currentDefault = try defaultInstanceStore.loadDefaultInstanceName()
            if currentDefault == name {
                let remaining = distributionManager
                    .installedInstances()
                    .filter(\.hasDisk)
                if let next = remaining.first(where: { !distributionManager.isReservedInternalInstanceName($0.name) })?.name {
                    try defaultInstanceStore.setDefaultInstanceName(next)
                    logger.log("default_instance_updated", fields: ["old": name, "new": next])
                } else {
                    try defaultInstanceStore.setDefaultInstanceName(nil)
                    logger.log("default_instance_updated", fields: ["old": name, "new": ""])
                }
            }

            return uninstallResult
        }

        print("uninstalled: \(result.removedInstancePath)")
        if let removedCachePath = result.removedCachePath {
            print("removed cache: \(removedCachePath)")
        } else if let keptCachePath = result.keptCachePath {
            print("kept cache: \(keptCachePath)")
        } else if !keepCache {
            print("removed cache: none")
        }
        Foundation.exit(0)
    }

    public func runContainerReset(instanceName rawName: String?) throws -> Never {
        let resolvedName = (rawName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? rawName!.trimmingCharacters(in: .whitespacesAndNewlines)
            : distributionManager.resolveContainerRuntimeInstanceName()

        let stateURL: URL = try lock.withExclusiveLock {
            let state = try store.loadState()
            if state.vmState == .running, state.distro == resolvedName {
                throw MSLRuntimeError("container runtime '\(resolvedName)' is running. run `msl stop \(resolvedName)` first.")
            }
            _ = try resolveContainerRuntimeTarget(explicitInstanceName: resolvedName)
            return try distributionManager.resetWritableState(name: resolvedName)
        }

        print("container state reset: \(stateURL.path)")
        Foundation.exit(0)
    }

    public func runDefaultShell(instanceName: String? = nil) throws -> Never {
        let commandStartMs = runtimeMonotonicMs()
        let metadataResolveStartMs = runtimeMonotonicMs()
        let target = try resolveRuntimeTarget(explicitInstanceName: instanceName)
        let metadata = try distributionManager.readOrRebuildInstanceMetadata(at: target.metadataURL)
        logger.log("startup_phase_duration_ms", fields: [
            "phase": "runtime_metadata_resolve",
            "elapsed_ms": String(max(0, runtimeMonotonicMs() - metadataResolveStartMs)),
            "instance": target.instanceName
        ])
        if metadata.resolvedStartupMode() == .processFirst {
            let resolvedInvocation = try resolveRunInvocation(argv: [], metadata: metadata)
            try runProcessFirstCommand(
                resolvedInvocation: resolvedInvocation,
                instanceName: target.instanceName,
                metadataURL: target.metadataURL,
                timeoutSec: 0,
                attachInput: true,
                usePTY: true,
                startMs: commandStartMs
            )
        }
        if metadata.shellAvailable == false {
            try runCommand(argv: [], timeoutSec: 0, instanceName: target.instanceName)
        }
        let workspacePolicy = evaluateWorkspaceStartupPolicy(instanceName: target.instanceName, metadataURL: target.metadataURL)

        // Ensure bootstrapped
        let bootstrapStartMs = runtimeMonotonicMs()
        try lock.withExclusiveLock {
            try bootstrap.ensureBootstrapped(context: .runtime)
        }
        logger.log("startup_phase_duration_ms", fields: [
            "phase": "bootstrap_total",
            "elapsed_ms": String(max(0, runtimeMonotonicMs() - bootstrapStartMs)),
            "instance": target.instanceName
        ])

        // Connect to daemon (auto-start if needed)
        try daemonClient.ensureConnected(
            expectedInstanceName: target.instanceName,
            hostShareRoot: resolveWorkspaceHostShareRoot(),
            callerCwd: currentCallerCwd()
        )
        prepareCacheSharingIfNeeded(instanceName: target.instanceName)
        let shellCwd = prepareWorkspaceIfNeeded(policy: workspacePolicy, instanceName: target.instanceName)

        // Register session
        let regResp = try daemonClient.send(RuntimeControlRequest(
            op: "session_register",
            instance: target.instanceName,
            callerCwd: currentCallerCwd()
        ))
        guard regResp.ok, let sessionID = regResp.sessionId else {
            throw MSLRuntimeError("failed to register session: \(regResp.error ?? "unknown")")
        }
        logger.log("shell_attached", fields: ["session": sessionID])

        // Open PTY
        let size = currentWindowSize()
        let openResp = try daemonClient.send(RuntimeControlRequest(
            op: "pty_open",
            rows: size.rows,
            cols: size.cols,
            sessionId: sessionID,
            cwd: shellCwd
        ))
        guard openResp.ok, let ptyId = openResp.ptyId else {
            _ = try? daemonClient.send(RuntimeControlRequest(op: "session_unregister", sessionId: sessionID))
            throw MSLRuntimeError("failed to open PTY: \(openResp.error ?? "unknown")")
        }
        logger.log("startup_phase_duration_ms", fields: [
            "phase": "first_shell_attach_ready",
            "elapsed_ms": String(max(0, runtimeMonotonicMs() - commandStartMs)),
            "instance": target.instanceName
        ])
        logger.log("startup_total_duration_ms", fields: [
            "elapsed_ms": String(max(0, runtimeMonotonicMs() - commandStartMs)),
            "instance": target.instanceName
        ])
        logger.log("init_pty_opened_via_daemon", fields: ["ptyId": ptyId])

        // Enter raw mode
        let hostTerminal = HostTerminalState.capture()
        enterRawModeForShell()
        let exitCode: Int32
        do {
            let result = try SessionStreamBridge.runPty(
                daemonClient: daemonClient,
                ptyID: ptyId,
                sessionID: sessionID,
                inputFD: FileHandle.standardInput.fileDescriptor,
                detachByte: 0x1d,
                onInputClosed: { [logger] reason, errnoValue in
                    var fields: [String: String] = [
                        "session": sessionID,
                        "phase": "stdin",
                        "event": reason
                    ]
                    if let errnoValue {
                        fields["errno"] = String(errnoValue)
                    }
                    logger.log("shell_attach_loop_breakpoint", fields: fields)
                },
                onOutput: { data in
                    FileHandle.standardOutput.write(data)
                    return true
                },
                onExitObserved: { [logger] code, reason in
                    var fields: [String: String] = [
                        "session": sessionID,
                        "phase": "pty_subscribe",
                        "event": "exit_code",
                        "exit": String(code)
                    ]
                    if let reason {
                        fields["exit_reason"] = reason
                    }
                    logger.log("shell_attach_loop_breakpoint", fields: fields)
                },
                resizeProvider: { [self] in currentWindowSize() },
                onResize: { [logger] rows, cols in
                    logger.log("shell_attach_loop_breakpoint", fields: [
                        "session": sessionID,
                        "phase": "pty_resize",
                        "rows": String(rows),
                        "cols": String(cols)
                    ])
                }
            )
            exitCode = result.exitCode
        } catch {
            hostTerminal.restore()
            if shouldTerminateInteractiveShellAttach(for: error) {
                logger.log("shell_attach_terminated_remote_stop", fields: [
                    "session": sessionID,
                    "phase": "pty_subscribe",
                    "error": String(describing: error)
                ])
                _ = try? daemonClient.send(RuntimeControlRequest(op: "pty_close", ptyId: ptyId, sessionId: sessionID))
                _ = try? daemonClient.send(RuntimeControlRequest(op: "session_unregister", sessionId: sessionID))
                daemonClient.disconnect()
                Foundation.exit(0)
            }
            throw error
        }

        // Restore terminal
        hostTerminal.restore()

        // Close PTY
        _ = try? daemonClient.send(RuntimeControlRequest(op: "pty_close", ptyId: ptyId, sessionId: sessionID))

        // Unregister session
        _ = try? daemonClient.send(RuntimeControlRequest(op: "session_unregister", sessionId: sessionID))

        daemonClient.disconnect()

        logger.log("runtime_command_completed", fields: [
            "session": sessionID,
            "elapsed_ms": String(runtimeMonotonicMs() - commandStartMs),
            "exit": String(exitCode)
        ])

        Foundation.exit(exitCode)
    }

    /// Run the VM worker process (entry point for `msl --_worker`).
    public func runWorker(instanceName: String? = nil) throws -> Never {
        let daemon = try DaemonServer(executablePath: executablePath, explicitInstanceName: instanceName)
        try daemon.run()
    }

    /// Run `msl provision`: compatibility readiness check for the init channel.
    public func runProvision(timeoutSec: Int = 600, instanceName: String? = nil) throws -> Never {
        let startMs = runtimeMonotonicMs()
        let target = try resolveRuntimeTarget(explicitInstanceName: instanceName)
        logger.log("provision_started")

        // Set up SIGINT handler for clean Ctrl+C exit
        installInterruptHandler()

        // Ensure bootstrapped
        try lock.withExclusiveLock {
            try bootstrap.ensureBootstrapped(context: .runtime)
        }

        // Connect to daemon
        try daemonClient.ensureConnected(
            expectedInstanceName: target.instanceName,
            hostShareRoot: resolveWorkspaceHostShareRoot(),
            callerCwd: currentCallerCwd()
        )

        // Register session
        let regResp = try daemonClient.send(RuntimeControlRequest(
            op: "session_register",
            instance: target.instanceName,
            callerCwd: currentCallerCwd()
        ))
        guard regResp.ok, let sessionID = regResp.sessionId else {
            throw MSLRuntimeError("failed to register session: \(regResp.error ?? "unknown")")
        }
        defer {
            _ = try? daemonClient.send(RuntimeControlRequest(op: "session_unregister", sessionId: sessionID))
            daemonClient.disconnect()
        }

        if isInterrupted() {
            fputs("\nmsl: readiness check interrupted by user\n", stderr)
            Foundation.exit(130)
        }

        let resp = try daemonClient.send(RuntimeControlRequest(op: "provision_status", sessionId: sessionID))
        guard resp.ok else {
            throw MSLRuntimeError(resp.error ?? "failed to check runtime readiness")
        }

        let convergence = resp.meta?["convergence"] ?? "unknown"
        let elapsed = runtimeMonotonicMs() - startMs
        logger.log("provision_completed", fields: [
            "elapsed_ms": String(elapsed),
            "convergence": convergence
        ])
        fputs("msl: runtime ready (\(convergence), \(elapsed / 1000)s)\n", stderr)
        Foundation.exit(0)
    }

    /// Run `msl run <cmd>`: execute a command in the VM.
    public func runCommand(argv: [String], timeoutSec: Int = 0, instanceName: String? = nil) throws -> Never {
        let startMs = runtimeMonotonicMs()
        let target = try resolveRuntimeTarget(explicitInstanceName: instanceName)
        let metadata = try distributionManager.readOrRebuildInstanceMetadata(at: target.metadataURL)
        let resolvedInvocation = try resolveRunInvocation(argv: argv, metadata: metadata)
        if metadata.resolvedStartupMode() == .processFirst {
            try runProcessFirstCommand(
                resolvedInvocation: resolvedInvocation,
                instanceName: target.instanceName,
                metadataURL: target.metadataURL,
                timeoutSec: timeoutSec,
                attachInput: argv.isEmpty,
                usePTY: argv.isEmpty,
                startMs: startMs
            )
        }
        let workspacePolicy = evaluateWorkspaceStartupPolicy(instanceName: target.instanceName, metadataURL: target.metadataURL)
        let resolvedArgv = resolvedInvocation.argv
        logger.log("run_command_started", fields: ["argv0": resolvedArgv[0]])
        if let startupNotice = resolvedInvocation.startupNotice {
            fputs("msl: \(startupNotice)\n", stderr)
        }

        // Ensure bootstrapped
        try lock.withExclusiveLock {
            try bootstrap.ensureBootstrapped(context: .runtime)
        }

        // Connect to daemon
        try daemonClient.ensureConnected(
            expectedInstanceName: target.instanceName,
            hostShareRoot: resolveWorkspaceHostShareRoot(),
            callerCwd: currentCallerCwd()
        )
        prepareCacheSharingIfNeeded(instanceName: target.instanceName)
        let workspaceExecCwd = prepareWorkspaceIfNeeded(policy: workspacePolicy, instanceName: target.instanceName)
        let execCwd = resolvedInvocation.cwd ?? workspaceExecCwd

        // Register session
        let regResp = try daemonClient.send(RuntimeControlRequest(
            op: "session_register",
            instance: target.instanceName,
            callerCwd: currentCallerCwd()
        ))
        guard regResp.ok, let sessionID = regResp.sessionId else {
            throw MSLRuntimeError("failed to register session: \(regResp.error ?? "unknown")")
        }
        defer {
            _ = try? daemonClient.send(RuntimeControlRequest(op: "session_unregister", sessionId: sessionID))
            daemonClient.disconnect()
        }

        // Send exec request
        let execTimeoutMs: Int? = timeoutSec > 0 ? timeoutSec * 1000 : nil
        let openResp = try daemonClient.send(RuntimeControlRequest(
            op: "proc_open",
            argv: resolvedArgv,
            timeoutMs: execTimeoutMs,
            runAsRoot: resolvedInvocation.runAsRoot || shouldForceRootRuntimeUser(),
            sessionId: sessionID,
            cwd: execCwd,
            envAdditions: resolvedInvocation.envAdditions
        ))
        guard openResp.ok, let procId = openResp.procId else {
            let errMsg = openResp.error ?? "proc_open failed"
            if shouldFallbackToLegacyExec(for: errMsg) {
                logger.log("run_command_fallback_exec", fields: [
                    "argv0": resolvedArgv[0],
                    "reason": errMsg
                ])
                _ = try? daemonClient.send(RuntimeControlRequest(op: "session_unregister", sessionId: sessionID))
                daemonClient.disconnect()
                try runCommandViaLegacyExec(
                    argv: resolvedArgv,
                    timeoutSec: timeoutSec,
                    targetInstanceName: target.instanceName,
                    execCwd: execCwd,
                    envAdditions: resolvedInvocation.envAdditions,
                    runAsRoot: resolvedInvocation.runAsRoot || shouldForceRootRuntimeUser(),
                    startMs: startMs
                )
            }
            logger.log("run_command_error", fields: [
                "argv0": resolvedArgv[0],
                "error": errMsg,
                "elapsed_ms": String(runtimeMonotonicMs() - startMs)
            ])
            fputs("msl: \(errMsg)\n", stderr)
            Foundation.exit(1)
        }
        defer {
            _ = try? daemonClient.send(RuntimeControlRequest(op: "proc_close", procId: procId, sessionId: sessionID))
        }

        do {
            let result = try SessionStreamBridge.runProc(
                daemonClient: daemonClient,
                procID: procId,
                sessionID: sessionID,
                inputFD: nil,
                attachInput: false,
                onOutput: { event in
                    switch event.kind {
                    case .stdout:
                        FileHandle.standardOutput.write(event.data)
                    case .stderr:
                        FileHandle.standardError.write(event.data)
                    }
                    return true
                }
            )
            let code = result.exitCode
            logger.log("run_command_completed", fields: [
                "argv0": resolvedArgv[0],
                "exit_code": String(code),
                "elapsed_ms": String(runtimeMonotonicMs() - startMs)
            ])
            Foundation.exit(code)
        } catch {
            let errMsg = String(describing: error)
            logger.log("run_command_error", fields: [
                "argv0": resolvedArgv[0],
                "error": errMsg,
                "elapsed_ms": String(runtimeMonotonicMs() - startMs)
            ])
            if shouldFallbackToLegacyExec(for: errMsg) {
                logger.log("run_command_fallback_exec", fields: [
                    "argv0": resolvedArgv[0],
                    "reason": errMsg
                ])
                _ = try? daemonClient.send(RuntimeControlRequest(op: "session_unregister", sessionId: sessionID))
                daemonClient.disconnect()
                try runCommandViaLegacyExec(
                    argv: resolvedArgv,
                    timeoutSec: timeoutSec,
                    targetInstanceName: target.instanceName,
                    execCwd: execCwd,
                    envAdditions: resolvedInvocation.envAdditions,
                    runAsRoot: resolvedInvocation.runAsRoot || shouldForceRootRuntimeUser(),
                    startMs: startMs
                )
            }
            fputs("msl: \(errMsg)\n", stderr)
            Foundation.exit(1)
        }
    }

    public func runNerdctl(argv: [String], instanceName: String? = nil) throws -> Never {
        let startMs = runtimeMonotonicMs()
        let target = try resolveContainerRuntimeTarget(explicitInstanceName: instanceName)
        let metadata = try distributionManager.readOrRebuildInstanceMetadata(at: target.metadataURL)
        guard metadata.resolvedWorkloadKind() == .containerRuntime else {
            throw MSLRuntimeError("msl nerdctl requires a container-runtime instance")
        }
        let workspacePlan = try resolveNerdctlWorkspacePlan(argv: argv)
        let effectiveNerdctlArgs = applyDefaultNerdctlSnapshotterIfNeeded(argv)
        let terminalMode = try resolveNerdctlTerminalModeForExecution(argv: effectiveNerdctlArgs)

        try lock.withExclusiveLock {
            try bootstrap.ensureBootstrapped(context: .runtime)
        }

        try daemonClient.ensureConnected(
            expectedInstanceName: target.instanceName,
            hostShareRoot: resolveWorkspaceHostShareRoot(),
            callerCwd: currentCallerCwd()
        )
        prepareCacheSharingIfNeeded(instanceName: target.instanceName)

        let nerdctlCwd: String?
        if workspacePlan.requiresWorkspace {
            let workspacePolicy = evaluateNerdctlWorkspacePolicy(
                instanceName: target.instanceName,
                metadataURL: target.metadataURL,
                metadata: metadata
            )
            guard workspacePolicy.workspaceGuestPath != nil else {
                throw MSLRuntimeError("build context not accessible from current workspace")
            }
            nerdctlCwd = prepareWorkspaceIfNeeded(policy: workspacePolicy, instanceName: target.instanceName)
            guard nerdctlCwd != nil else {
                throw MSLRuntimeError("workspace mount failed for nerdctl")
            }
        } else {
            nerdctlCwd = nil
        }
        let nerdctlArgv = ["/usr/local/bin/nerdctl"] + effectiveNerdctlArgs
        let nerdctlEnv = nerdctlEnvironment()
        applyNerdctlPublishedPortMappingsIfNeeded(
            argv: argv,
            instanceName: target.instanceName,
            daemonClient: daemonClient
        )

        logger.log("nerdctl_started", fields: [
            "instance": target.instanceName,
            "argv0": nerdctlArgv[0],
            "transport": terminalMode.transport
        ])

        let exitCode = try executeNerdctlViaDaemon(
            daemonClient: daemonClient,
            instanceName: target.instanceName,
            argv: nerdctlArgv,
            cwd: nerdctlCwd,
            envAdditions: nerdctlEnv,
            terminalMode: terminalMode,
            startMs: startMs,
            logPrefix: "nerdctl"
        ).exitCode
        Foundation.exit(exitCode)
    }

    private func applyNerdctlPublishedPortMappingsIfNeeded(
        argv: [String],
        instanceName: String,
        daemonClient: DaemonClient
    ) {
        let mappings = NerdctlPortPublishing.directForwardMappings(from: argv, instanceName: instanceName)
        guard !mappings.isEmpty else {
            return
        }

        persistNerdctlPublishedPortMappings(mappings, instanceName: instanceName, daemonClient: daemonClient)
    }

    private func logNerdctlPortForwardApplyResult(
        response: RuntimeControlResponse,
        mappings: [PortMapping],
        instanceName: String,
        backend: String
    ) {
        if let failed = response.items?.first(where: { $0.active == false || $0.error != nil }) {
            logger.log("nerdctl_port_forward_apply_failed", fields: [
                "instance": instanceName,
                "backend": backend,
                "hostPort": String(failed.hostPort),
                "guestPort": String(failed.guestPort),
                "error": failed.error ?? "inactive"
            ])
        } else {
            logger.log("nerdctl_port_forward_applied", fields: [
                "instance": instanceName,
                "backend": backend,
                "ports": mappings.map { "\($0.hostPort):\($0.guestPort)" }.joined(separator: ",")
            ])
        }
    }

    private func persistNerdctlPublishedPortMappings(
        _ mappings: [PortMapping],
        instanceName: String,
        daemonClient: DaemonClient
    ) {
        do {
            var applied: [PortMapping] = []
            try lock.withExclusiveLock {
                var state = try store.loadPortMappings()
                var changed = false
                for mapping in mappings {
                    if let existingIndex = state.mappings.firstIndex(where: { $0.hostPort == mapping.hostPort }) {
                        let existing = state.mappings[existingIndex]
                        if existing.instance == instanceName {
                            if existing != mapping {
                                state.mappings[existingIndex] = mapping
                                changed = true
                            }
                            applied.append(mapping)
                        } else {
                            logger.log("nerdctl_port_forward_conflict", fields: [
                                "instance": instanceName,
                                "hostPort": String(mapping.hostPort),
                                "ownerInstance": existing.instance
                            ])
                        }
                        continue
                    }
                    state.mappings.append(mapping)
                    applied.append(mapping)
                    changed = true
                }
                if changed {
                    state.mappings.sort { lhs, rhs in
                        if lhs.hostPort == rhs.hostPort {
                            return lhs.instance < rhs.instance
                        }
                        return lhs.hostPort < rhs.hostPort
                    }
                    try store.savePortMappings(state)
                }
            }

            for mapping in applied {
                let response = try? daemonClient.send(RuntimeControlRequest(
                    op: "port_add",
                    instance: instanceName,
                    hostPort: mapping.hostPort,
                    guestPort: mapping.guestPort
                ))
                if response?.ok == false {
                    logger.log("nerdctl_port_forward_control_failed", fields: [
                        "instance": instanceName,
                        "hostPort": String(mapping.hostPort),
                        "error": response?.error ?? "unknown"
                    ])
                }
            }
        } catch {
            logger.log("nerdctl_port_forward_persist_failed", fields: [
                "instance": instanceName,
                "error": String(describing: error)
            ])
        }
    }

    func resolveRunInvocation(
        argv: [String],
        metadata: DistributionInstanceMetadata
    ) throws -> ResolvedRunInvocation {
        if !argv.isEmpty {
            return ResolvedRunInvocation(
                argv: argv,
                cwd: nil,
                envAdditions: nil,
                runAsRoot: false,
                startupNotice: nil
            )
        }

        if metadata.resolvedWorkloadKind() == .containerRuntime {
            guard let defaultExec = metadata.defaultExec, !defaultExec.argv.isEmpty else {
                throw MSLRuntimeError("default command is not configured for this container-runtime instance")
            }
            return ResolvedRunInvocation(
                argv: defaultExec.argv,
                cwd: sanitizeOptionalPath(defaultExec.workingDir),
                envAdditions: parseEnvAdditions(defaultExec.env),
                runAsRoot: true,
                startupNotice: "interactive shell is unavailable in process-first mode; starting configured default command instead"
            )
        }

        if metadata.shellAvailable != false {
            let shell = metadata.userConvergencePolicy?.shellFallbacks.first ?? "/bin/sh"
            return ResolvedRunInvocation(
                argv: [shell, "-l"],
                cwd: nil,
                envAdditions: nil,
                runAsRoot: false,
                startupNotice: nil
            )
        }

        guard let defaultExec = metadata.defaultExec, !defaultExec.argv.isEmpty else {
            throw MSLRuntimeError("interactive shell is unavailable for this instance and no default command is configured")
        }

        return ResolvedRunInvocation(
            argv: defaultExec.argv,
            cwd: sanitizeOptionalPath(defaultExec.workingDir),
            envAdditions: parseEnvAdditions(defaultExec.env),
            runAsRoot: shouldRunAsRoot(for: defaultExec.user),
            startupNotice: "interactive shell is unavailable for this image; starting configured default command instead"
        )
    }

    private func sanitizeOptionalPath(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func parseEnvAdditions(_ items: [String]) -> [String: String]? {
        var additions: [String: String] = [:]
        for item in items {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let separator = trimmed.firstIndex(of: "=") else {
                continue
            }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            let value = String(trimmed[trimmed.index(after: separator)...])
            additions[key] = value
        }
        return additions.isEmpty ? nil : additions
    }

    private func shouldRunAsRoot(for requestedUser: String?) -> Bool {
        guard let requestedUser else { return false }
        let trimmed = requestedUser.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "root" || trimmed == "0"
    }

    private func shouldFallbackToLegacyExec(for errorMessage: String) -> Bool {
        let lowered = errorMessage.lowercased()
        return lowered.contains("vsock connection closed by guest")
            || lowered.contains("vsock write failed: broken pipe")
            || lowered.contains("broken pipe")
            || lowered.contains("vsock read timeout")
            || lowered.contains("read timeout")
    }

    private func runProcessFirstCommand(
        resolvedInvocation: ResolvedRunInvocation,
        instanceName: String,
        metadataURL: URL,
        timeoutSec: Int,
        attachInput: Bool,
        usePTY: Bool,
        startMs: Int64
    ) throws -> Never {
        let resolvedArgv = resolvedInvocation.argv
        logger.log("process_first_command_started", fields: [
            "instance": instanceName,
            "argv0": resolvedArgv[0],
            "transport": usePTY ? "direct_init_pty" : "direct_init_proc"
        ])
        if let startupNotice = resolvedInvocation.startupNotice {
            fputs("msl: \(startupNotice)\n", stderr)
        }

        try lock.withExclusiveLock {
            try bootstrap.ensureBootstrapped(context: .runtime)
        }

        let runner = try makeDirectVirtualMachineRunner(metadataURL: metadataURL, instanceName: instanceName)
        let client = try runner.startVMForDaemon()
        defer {
            runner.stopRunningVM()
        }
        do {
            let exitCode = try executeDirectInitCommand(
                client: client,
                instanceName: instanceName,
                argv: resolvedArgv,
                cwd: resolvedInvocation.cwd,
                envAdditions: resolvedInvocation.envAdditions,
                runAsRoot: resolvedInvocation.runAsRoot || shouldForceRootRuntimeUser(),
                timeoutSec: timeoutSec,
                attachInput: attachInput,
                usePTY: usePTY,
                emitOutput: true,
                startMs: startMs,
                logPrefix: "process_first_command"
            )
            Foundation.exit(exitCode)
        } catch {
            let message = String(describing: error)
            logger.log("process_first_command_failed", fields: [
                "instance": instanceName,
                "argv0": resolvedArgv[0],
                "error": message,
                "elapsed_ms": String(runtimeMonotonicMs() - startMs)
            ])
            fputs("msl: process_start_failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }

    private func executeNerdctlDirectInit(
        client: InitChannelClient,
        instanceName: String,
        argv: [String],
        cwd: String?,
        envAdditions: [String: String],
        terminalMode: NerdctlTerminalMode,
        startMs: Int64,
        logPrefix: String
    ) throws -> NerdctlExecutionResult {
        switch terminalMode {
        case .interactivePTY, .displayPTY:
            return try executeDirectInitPtyCommandCapturingOutput(
                client: client,
                instanceName: instanceName,
                argv: argv,
                cwd: cwd,
                envAdditions: envAdditions,
                runAsRoot: true,
                timeoutSec: 0,
                attachInput: terminalMode == .interactivePTY,
                emitOutput: true,
                startMs: startMs,
                logPrefix: logPrefix
            )
        case .streamingProc:
            return try executeDirectInitStreamingProcCapturingOutput(
                client: client,
                instanceName: instanceName,
                argv: argv,
                cwd: cwd,
                envAdditions: envAdditions,
                runAsRoot: true,
                startMs: startMs,
                logPrefix: logPrefix
            )
        }
    }

    private func executeNerdctlViaDaemon(
        daemonClient: DaemonClient,
        instanceName: String,
        argv: [String],
        cwd: String?,
        envAdditions: [String: String],
        terminalMode: NerdctlTerminalMode,
        startMs: Int64,
        logPrefix: String
    ) throws -> NerdctlExecutionResult {
        let regResp = try daemonClient.send(RuntimeControlRequest(
            op: "session_register",
            instance: instanceName,
            callerCwd: currentCallerCwd()
        ))
        guard regResp.ok, let sessionID = regResp.sessionId else {
            throw MSLRuntimeError("failed to register nerdctl session: \(regResp.error ?? "unknown")")
        }
        defer {
            _ = try? daemonClient.send(RuntimeControlRequest(op: "session_unregister", sessionId: sessionID))
        }

        switch terminalMode {
        case .interactivePTY, .displayPTY:
            return try executeNerdctlDaemonPTY(
                daemonClient: daemonClient,
                sessionID: sessionID,
                instanceName: instanceName,
                argv: argv,
                cwd: cwd,
                envAdditions: envAdditions,
                attachInput: terminalMode == .interactivePTY,
                startMs: startMs,
                logPrefix: logPrefix
            )
        case .streamingProc:
            return try executeNerdctlDaemonProc(
                daemonClient: daemonClient,
                sessionID: sessionID,
                instanceName: instanceName,
                argv: argv,
                cwd: cwd,
                envAdditions: envAdditions,
                startMs: startMs,
                logPrefix: logPrefix
            )
        }
    }

    private func executeNerdctlDaemonPTY(
        daemonClient: DaemonClient,
        sessionID: String,
        instanceName: String,
        argv: [String],
        cwd: String?,
        envAdditions: [String: String],
        attachInput: Bool,
        startMs: Int64,
        logPrefix: String
    ) throws -> NerdctlExecutionResult {
        let size = currentWindowSize()
        let openResp = try daemonClient.send(RuntimeControlRequest(
            op: "pty_open",
            argv: argv,
            runAsRoot: true,
            rows: size.rows,
            cols: size.cols,
            sessionId: sessionID,
            cwd: cwd,
            envAdditions: envAdditions
        ))
        guard openResp.ok, let ptyId = openResp.ptyId else {
            throw MSLRuntimeError("failed to open nerdctl PTY: \(openResp.error ?? "unknown")")
        }

        let capture = RollingOutputCapture()
        let hostTerminal = attachInput ? HostTerminalState.capture() : nil
        if attachInput {
            enterRawModeForShell()
        }
        do {
            let result = try SessionStreamBridge.runPty(
                daemonClient: daemonClient,
                ptyID: ptyId,
                sessionID: sessionID,
                inputFD: attachInput ? FileHandle.standardInput.fileDescriptor : nil,
                detachByte: 0x1d,
                onOutput: { data in
                    capture.append(data)
                    FileHandle.standardOutput.write(data)
                    return true
                },
                onExitObserved: { [logger] code, reason in
                    var fields: [String: String] = [
                        "instance": instanceName,
                        "phase": logPrefix,
                        "exit": String(code)
                    ]
                    if let reason {
                        fields["exit_reason"] = reason
                    }
                    logger.log("\(logPrefix)_exit_observed", fields: fields)
                },
                resizeProvider: { [self] in currentWindowSize() }
            )
            hostTerminal?.restore()
            logger.log("\(logPrefix)_completed", fields: [
                "instance": instanceName,
                "argv0": argv[0],
                "exit_code": String(result.exitCode),
                "elapsed_ms": String(runtimeMonotonicMs() - startMs),
                "transport": attachInput ? "daemon_interactive_pty" : "daemon_display_pty"
            ])
            return NerdctlExecutionResult(exitCode: result.exitCode, capturedOutput: capture.stringValue)
        } catch {
            hostTerminal?.restore()
            throw error
        }
    }

    private func executeNerdctlDaemonProc(
        daemonClient: DaemonClient,
        sessionID: String,
        instanceName: String,
        argv: [String],
        cwd: String?,
        envAdditions: [String: String],
        startMs: Int64,
        logPrefix: String
    ) throws -> NerdctlExecutionResult {
        let openResp = try daemonClient.send(RuntimeControlRequest(
            op: "proc_open",
            argv: argv,
            runAsRoot: true,
            sessionId: sessionID,
            cwd: cwd,
            envAdditions: envAdditions
        ))
        guard openResp.ok, let procId = openResp.procId else {
            throw MSLRuntimeError("failed to open nerdctl process: \(openResp.error ?? "unknown")")
        }

        let capture = RollingOutputCapture()
        let result = try SessionStreamBridge.runProc(
            daemonClient: daemonClient,
            procID: procId,
            sessionID: sessionID,
            inputFD: nil,
            attachInput: false,
            onOutput: { event in
                capture.append(event.data)
                switch event.kind {
                case .stdout:
                    FileHandle.standardOutput.write(event.data)
                case .stderr:
                    FileHandle.standardError.write(event.data)
                }
                return true
            },
            onExitObserved: { [logger] code, reason in
                var fields: [String: String] = [
                    "instance": instanceName,
                    "phase": logPrefix,
                    "exit": String(code)
                ]
                if let reason {
                    fields["exit_reason"] = reason
                }
                logger.log("\(logPrefix)_exit_observed", fields: fields)
            }
        )
        logger.log("\(logPrefix)_completed", fields: [
            "instance": instanceName,
            "argv0": argv[0],
            "exit_code": String(result.exitCode),
            "elapsed_ms": String(runtimeMonotonicMs() - startMs),
            "transport": "daemon_proc_stream"
        ])
        return NerdctlExecutionResult(exitCode: result.exitCode, capturedOutput: capture.stringValue)
    }

    private func ensureContainerRuntimeCachePolicy(
        client: InitChannelClient,
        instanceName: String
    ) throws {
        let script = """
        set -eu
        marker_dir=/var/lib/msl
        marker="$marker_dir/container-runtime-cache-policy"
        policy=native-v1
        if [ -f "$marker" ] && [ "$(cat "$marker" 2>/dev/null || true)" = "$policy" ]; then
          exit 0
        fi
        rc-service buildkitd stop >/dev/null 2>&1 || true
        rc-service containerd stop >/dev/null 2>&1 || true
        rm -rf /var/lib/containerd /var/lib/buildkit
        mkdir -p /var/lib/containerd /var/lib/buildkit "$marker_dir"
        printf '%s\n' "$policy" > "$marker"
        """
        let exitCode = try executeDirectInitCommand(
            client: client,
            instanceName: instanceName,
            argv: ["/bin/sh", "-lc", script],
            cwd: nil,
            envAdditions: nil,
            runAsRoot: true,
            timeoutSec: 30,
            attachInput: false,
            usePTY: false,
            emitOutput: false,
            startMs: runtimeMonotonicMs(),
            logPrefix: "container_runtime_cache_policy"
        )
        guard exitCode == 0 else {
            throw MSLRuntimeError("failed to initialize container-runtime native snapshotter cache policy")
        }
    }

    private func flushContainerRuntimeDisk(
        client: InitChannelClient,
        instanceName: String
    ) {
        do {
            let exitCode = try executeDirectInitCommand(
                client: client,
                instanceName: instanceName,
                argv: ["/bin/sync"],
                cwd: nil,
                envAdditions: nil,
                runAsRoot: true,
                timeoutSec: 3,
                attachInput: false,
                usePTY: false,
                emitOutput: false,
                startMs: runtimeMonotonicMs(),
                logPrefix: "container_runtime_flush"
            )
            logger.log("container_runtime_flush_completed", fields: [
                "instance": instanceName,
                "exit_code": String(exitCode)
            ])
        } catch {
            logger.log("container_runtime_flush_failed", fields: [
                "instance": instanceName,
                "error": String(describing: error)
            ])
        }
    }

    private func ensureContainerRuntimeService(
        _ service: String,
        client: InitChannelClient,
        instanceName: String
    ) throws {
        let socketPath = containerRuntimeSocketPath(for: service)
        let statusCode = try executeDirectInitCommand(
            client: client,
            instanceName: instanceName,
            argv: ["/sbin/rc-service", service, "status"],
            cwd: nil,
            envAdditions: nil,
            runAsRoot: true,
            timeoutSec: 15,
            attachInput: false,
            usePTY: false,
            emitOutput: false,
            startMs: runtimeMonotonicMs(),
            logPrefix: "runtime_service_status"
        )
        if statusCode == 0 {
            try waitForContainerRuntimeSocketIfNeeded(
                service: service,
                socketPath: socketPath,
                client: client,
                instanceName: instanceName
            )
            return
        }

        let startCode = try executeDirectInitCommand(
            client: client,
            instanceName: instanceName,
            argv: ["/sbin/rc-service", service, "start"],
            cwd: nil,
            envAdditions: nil,
            runAsRoot: true,
            timeoutSec: 60,
            attachInput: false,
            usePTY: false,
            emitOutput: false,
            startMs: runtimeMonotonicMs(),
            logPrefix: "runtime_service_start"
        )
        guard startCode == 0 else {
            throw MSLRuntimeError("failed to start \(service) in container-runtime instance '\(instanceName)'")
        }
        try waitForContainerRuntimeSocketIfNeeded(
            service: service,
            socketPath: socketPath,
            client: client,
            instanceName: instanceName
        )
    }

    private func ensureContainerRuntimeServiceManagerInitialized(
        client: InitChannelClient,
        instanceName: String
    ) throws {
        let initCode = try executeDirectInitCommand(
            client: client,
            instanceName: instanceName,
            argv: [
                "/bin/sh", "-lc",
                "mkdir -p /run/openrc && [ -f /run/openrc/softlevel ] || printf 'default\\n' > /run/openrc/softlevel"
            ],
            cwd: nil,
            envAdditions: nil,
            runAsRoot: true,
            timeoutSec: 15,
            attachInput: false,
            usePTY: false,
            emitOutput: false,
            startMs: runtimeMonotonicMs(),
            logPrefix: "runtime_service_manager_init"
        )
        guard initCode == 0 else {
            throw MSLRuntimeError("failed to initialize openrc runtime state in container-runtime instance '\(instanceName)'")
        }
    }

    private func containerRuntimeSocketPath(for service: String) -> String? {
        switch service {
        case "containerd":
            return "/run/containerd/containerd.sock"
        case "buildkitd":
            return "/run/buildkit/buildkitd.sock"
        default:
            return nil
        }
    }

    private func waitForContainerRuntimeSocketIfNeeded(
        service: String,
        socketPath: String?,
        client: InitChannelClient,
        instanceName: String
    ) throws {
        guard let socketPath else { return }
        let escapedPath = socketPath.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        i=0
        while [ "$i" -lt 50 ]; do
          [ -S '\(escapedPath)' ] && exit 0
          sleep 0.1
          i=$((i + 1))
        done
        exit 1
        """
        let waitCode = try executeDirectInitCommand(
            client: client,
            instanceName: instanceName,
            argv: ["/bin/sh", "-lc", script],
            cwd: nil,
            envAdditions: nil,
            runAsRoot: true,
            timeoutSec: 10,
            attachInput: false,
            usePTY: false,
            emitOutput: false,
            startMs: runtimeMonotonicMs(),
            logPrefix: "runtime_service_socket_wait"
        )
        guard waitCode == 0 else {
            throw MSLRuntimeError("\(service) did not become ready in container-runtime instance '\(instanceName)' (missing socket \(socketPath))")
        }
    }

    private func reconcileDirectRuntimeDNS(
        client: InitChannelClient,
        runner: VirtualMachineRunner,
        instanceName: String,
        metadata: DistributionInstanceMetadata
    ) throws {
        let config = try defaultInstanceStore.loadConfig()
        let snapshot = HostResolverSnapshotProvider().capture()
        let policy = try DNSPolicyResolver().resolve(
            instancePolicy: metadata.networkPolicy?.dns,
            globalConfig: config.network?.dns,
            hostSnapshot: snapshot
        )
        if policy.mode == .unmanaged {
            return
        }

        let apply = try client.send(InitChannelRequest(
            op: "dns_reconcile",
            timeoutMs: 3_000,
            dnsMode: policy.mode.rawValue,
            dnsNameservers: policy.nameservers,
            dnsSearchDomains: policy.searchDomains,
            dnsResolverBackend: policy.resolverBackend,
            dnsSource: "runtime_direct",
            dnsProxyUpstreams: policy.mode == .host ? policy.nameservers : nil,
            dnsProxyListenAddress: policy.mode == .host ? "127.0.0.1" : nil,
            dnsProxyListenPort: policy.mode == .host ? 53 : nil
        ))
        if !apply.ok {
            throw MSLRuntimeError(apply.error?.message ?? "dns reconcile failed")
        }

        let transportReady = ensureGuestTransportReadyViaExec(
            client: client,
            topology: runner.activeNetworkTopology
        )
        if !transportReady.ok {
            throw MSLRuntimeError(transportReady.error ?? "guest transport bootstrap failed")
        }

        let healthcheck = try client.send(InitChannelRequest(
            op: "dns_healthcheck",
            timeoutMs: 2_000,
            dnsMode: policy.mode.rawValue,
            dnsSource: "runtime_direct"
        ))
        if !healthcheck.ok {
            throw MSLRuntimeError(healthcheck.error?.message ?? "dns healthcheck failed")
        }
    }

    private func ensureGuestTransportReadyViaExec(
        client: InitChannelClient,
        topology: VMNetNetworkTopology?
    ) -> (ok: Bool, error: String?) {
        let script = DaemonServer.makeGuestTransportReadyScript(topology: topology)

        do {
            let response = try client.send(InitChannelRequest(
                op: "exec",
                argv: ["/bin/sh", "-lc", script],
                runAsRoot: true,
                timeoutMs: 8_000
            ))
            if response.ok, (response.exitCode ?? 1) == 0 {
                return (true, nil)
            }
            let error = response.error?.message ?? response.stderr ?? "missing default route or global ipv4/ipv6 address"
            return (false, "network transport unavailable: \(error)")
        } catch {
            return (false, "network transport bootstrap init_channel error: \(error)")
        }
    }

    private func executeDirectInitCommand(
        client: InitChannelClient,
        instanceName: String,
        argv: [String],
        cwd: String?,
        envAdditions: [String: String]?,
        runAsRoot: Bool,
        timeoutSec: Int,
        attachInput: Bool,
        usePTY: Bool,
        emitOutput: Bool,
        startMs: Int64,
        logPrefix: String
    ) throws -> Int32 {
        if usePTY {
            let size = currentWindowSize()
            let openResp = try client.ptyOpen(
                argv: argv,
                cwd: cwd,
                envAdditions: envAdditions,
                runAsRoot: runAsRoot,
                rows: size.rows,
                cols: size.cols,
                timeoutMs: timeoutSec > 0 ? timeoutSec * 1000 : nil
            )
            guard openResp.ok, let ptyId = openResp.ptyId else {
                throw MSLRuntimeError(openResp.error?.message ?? "process_start_failed: pty_open failed")
            }
            let hostTerminal = attachInput ? HostTerminalState.capture() : nil
            if attachInput {
                enterRawModeForShell()
            }
            do {
                let result = try SessionStreamBridge.runPty(
                    initClient: client,
                    ptyID: ptyId,
                    inputFD: attachInput ? FileHandle.standardInput.fileDescriptor : nil,
                    detachByte: 0x1d,
                    onOutput: { data in
                        if emitOutput {
                            FileHandle.standardOutput.write(data)
                        }
                        return true
                    },
                    onExitObserved: { [logger] code, reason in
                        var fields: [String: String] = [
                            "instance": instanceName,
                            "phase": logPrefix,
                            "exit": String(code)
                        ]
                        if let reason {
                            fields["exit_reason"] = reason
                        }
                        logger.log("\(logPrefix)_exit_observed", fields: fields)
                    },
                    resizeProvider: { [self] in currentWindowSize() }
                )
                hostTerminal?.restore()
                logger.log("\(logPrefix)_completed", fields: [
                    "instance": instanceName,
                    "argv0": argv[0],
                    "exit_code": String(result.exitCode),
                    "elapsed_ms": String(runtimeMonotonicMs() - startMs),
                    "transport": attachInput ? "direct_init_interactive_pty" : "direct_init_display_pty"
                ])
                return result.exitCode
            } catch {
                hostTerminal?.restore()
                throw error
            }
        }

        if !attachInput {
            let response = try client.send(InitChannelRequest(
                op: "exec",
                argv: argv,
                envAdditions: envAdditions,
                runAsRoot: runAsRoot,
                cwd: cwd,
                timeoutMs: timeoutSec > 0 ? timeoutSec * 1000 : nil
            ))
            guard response.ok else {
                throw MSLRuntimeError(response.error?.message ?? "process_start_failed: exec failed")
            }
            if emitOutput {
                if let stdout = response.rawStdout ?? response.stdout.map({ Data($0.utf8) }), !stdout.isEmpty {
                    FileHandle.standardOutput.write(stdout)
                }
                if let stderr = response.rawStderr ?? response.stderr.map({ Data($0.utf8) }), !stderr.isEmpty {
                    FileHandle.standardError.write(stderr)
                }
            }
            let exitCode = response.exitCode ?? 0
            logger.log("\(logPrefix)_completed", fields: [
                "instance": instanceName,
                "argv0": argv[0],
                "exit_code": String(exitCode),
                "elapsed_ms": String(runtimeMonotonicMs() - startMs),
                "transport": "direct_init_exec"
            ])
            return exitCode
        }

        let openResp = try client.procOpen(
            argv: argv,
            cwd: cwd,
            envAdditions: envAdditions,
            runAsRoot: runAsRoot,
            timeoutMs: timeoutSec > 0 ? timeoutSec * 1000 : nil
        )
        guard openResp.ok, let procId = openResp.procId else {
            throw MSLRuntimeError(openResp.error?.message ?? "process_start_failed: proc_open failed")
        }

        let result = try SessionStreamBridge.runProc(
            initClient: client,
            procID: procId,
            inputFD: attachInput ? FileHandle.standardInput.fileDescriptor : nil,
            attachInput: attachInput,
            onOutput: { event in
                guard emitOutput else { return true }
                switch event.kind {
                case .stdout:
                    FileHandle.standardOutput.write(event.data)
                case .stderr:
                    FileHandle.standardError.write(event.data)
                }
                return true
            }
        )
        logger.log("\(logPrefix)_completed", fields: [
            "instance": instanceName,
            "argv0": argv[0],
            "exit_code": String(result.exitCode),
            "elapsed_ms": String(runtimeMonotonicMs() - startMs),
            "transport": "direct_init_proc"
        ])
        return result.exitCode
    }

    private func executeDirectInitStreamingProc(
        client: InitChannelClient,
        instanceName: String,
        argv: [String],
        cwd: String?,
        envAdditions: [String: String]?,
        runAsRoot: Bool,
        startMs: Int64,
        logPrefix: String
    ) throws -> Int32 {
        let openResp = try client.procOpen(
            argv: argv,
            cwd: cwd,
            envAdditions: envAdditions,
            runAsRoot: runAsRoot,
            timeoutMs: nil
        )
        guard openResp.ok, let procId = openResp.procId else {
            throw MSLRuntimeError(openResp.error?.message ?? "process_start_failed: proc_open failed")
        }

        let result = try SessionStreamBridge.runProc(
            initClient: client,
            procID: procId,
            inputFD: nil,
            attachInput: false,
            onOutput: { event in
                switch event.kind {
                case .stdout:
                    FileHandle.standardOutput.write(event.data)
                case .stderr:
                    FileHandle.standardError.write(event.data)
                }
                return true
            },
            onExitObserved: { [logger] code, reason in
                var fields: [String: String] = [
                    "instance": instanceName,
                    "phase": logPrefix,
                    "exit": String(code)
                ]
                if let reason {
                    fields["exit_reason"] = reason
                }
                logger.log("\(logPrefix)_exit_observed", fields: fields)
            }
        )
        logger.log("\(logPrefix)_completed", fields: [
            "instance": instanceName,
            "argv0": argv[0],
            "exit_code": String(result.exitCode),
            "elapsed_ms": String(runtimeMonotonicMs() - startMs),
            "transport": "direct_init_proc_stream"
        ])
        return result.exitCode
    }

    private func executeDirectInitPtyCommandCapturingOutput(
        client: InitChannelClient,
        instanceName: String,
        argv: [String],
        cwd: String?,
        envAdditions: [String: String]?,
        runAsRoot: Bool,
        timeoutSec: Int,
        attachInput: Bool,
        emitOutput: Bool,
        startMs: Int64,
        logPrefix: String
    ) throws -> NerdctlExecutionResult {
        let size = currentWindowSize()
        let openResp = try client.ptyOpen(
            argv: argv,
            cwd: cwd,
            envAdditions: envAdditions,
            runAsRoot: runAsRoot,
            rows: size.rows,
            cols: size.cols,
            timeoutMs: timeoutSec > 0 ? timeoutSec * 1000 : nil
        )
        guard openResp.ok, let ptyId = openResp.ptyId else {
            throw MSLRuntimeError(openResp.error?.message ?? "process_start_failed: pty_open failed")
        }
        let capture = RollingOutputCapture()
        let hostTerminal = attachInput ? HostTerminalState.capture() : nil
        if attachInput {
            enterRawModeForShell()
        }
        do {
            let result = try SessionStreamBridge.runPty(
                initClient: client,
                ptyID: ptyId,
                inputFD: attachInput ? FileHandle.standardInput.fileDescriptor : nil,
                detachByte: 0x1d,
                onOutput: { data in
                    capture.append(data)
                    if emitOutput {
                        FileHandle.standardOutput.write(data)
                    }
                    return true
                },
                onExitObserved: { [logger] code, reason in
                    var fields: [String: String] = [
                        "instance": instanceName,
                        "phase": logPrefix,
                        "exit": String(code)
                    ]
                    if let reason {
                        fields["exit_reason"] = reason
                    }
                    logger.log("\(logPrefix)_exit_observed", fields: fields)
                },
                resizeProvider: { [self] in currentWindowSize() }
            )
            hostTerminal?.restore()
            logger.log("\(logPrefix)_completed", fields: [
                "instance": instanceName,
                "argv0": argv[0],
                "exit_code": String(result.exitCode),
                "elapsed_ms": String(runtimeMonotonicMs() - startMs),
                "transport": attachInput ? "direct_init_interactive_pty" : "direct_init_display_pty"
            ])
            return NerdctlExecutionResult(exitCode: result.exitCode, capturedOutput: capture.stringValue)
        } catch {
            hostTerminal?.restore()
            throw error
        }
    }

    private func executeDirectInitStreamingProcCapturingOutput(
        client: InitChannelClient,
        instanceName: String,
        argv: [String],
        cwd: String?,
        envAdditions: [String: String]?,
        runAsRoot: Bool,
        startMs: Int64,
        logPrefix: String
    ) throws -> NerdctlExecutionResult {
        let openResp = try client.procOpen(
            argv: argv,
            cwd: cwd,
            envAdditions: envAdditions,
            runAsRoot: runAsRoot,
            timeoutMs: nil
        )
        guard openResp.ok, let procId = openResp.procId else {
            throw MSLRuntimeError(openResp.error?.message ?? "process_start_failed: proc_open failed")
        }

        let capture = RollingOutputCapture()
        let result = try SessionStreamBridge.runProc(
            initClient: client,
            procID: procId,
            inputFD: nil,
            attachInput: false,
            onOutput: { event in
                capture.append(event.data)
                switch event.kind {
                case .stdout:
                    FileHandle.standardOutput.write(event.data)
                case .stderr:
                    FileHandle.standardError.write(event.data)
                }
                return true
            },
            onExitObserved: { [logger] code, reason in
                var fields: [String: String] = [
                    "instance": instanceName,
                    "phase": logPrefix,
                    "exit": String(code)
                ]
                if let reason {
                    fields["exit_reason"] = reason
                }
                logger.log("\(logPrefix)_exit_observed", fields: fields)
            }
        )
        logger.log("\(logPrefix)_completed", fields: [
            "instance": instanceName,
            "argv0": argv[0],
            "exit_code": String(result.exitCode),
            "elapsed_ms": String(runtimeMonotonicMs() - startMs),
            "transport": "direct_init_proc_stream"
        ])
        return NerdctlExecutionResult(exitCode: result.exitCode, capturedOutput: capture.stringValue)
    }

    private func makeDirectVirtualMachineRunner(
        metadataURL: URL,
        instanceName: String
    ) throws -> VirtualMachineRunner {
        let configKernel = try defaultInstanceStore.loadDefaultKernelProfileRef()
        let bootProfile = try RuntimeBootProfileResolver(
            paths: paths,
            logger: logger,
            environment: ProcessInfo.processInfo.environment
        ).resolve(
            metadataURL: metadataURL,
            instanceName: instanceName,
            defaultKernelProfileRef: configKernel
        )
        let resolvedNetworkMode = NetworkModeResolver.resolve(
            configured: NetworkModeResolver.configuredMode(from: try? defaultInstanceStore.loadConfig()),
            executablePath: executablePath
        )
        return VirtualMachineRunner(
            paths: paths,
            metadataURL: metadataURL,
            bootProfile: bootProfile,
            logger: logger,
            initProbeHandler: { [weak self] probe in
                self?.updateInitChannelState(probe)
            },
            networkMode: resolvedNetworkMode.effective
        )
    }

    private func runCommandViaLegacyExec(
        argv: [String],
        timeoutSec: Int,
        targetInstanceName: String,
        execCwd: String?,
        envAdditions: [String: String]?,
        runAsRoot: Bool,
        startMs: Int64
    ) throws -> Never {
        try daemonClient.ensureConnected(
            expectedInstanceName: targetInstanceName,
            hostShareRoot: resolveWorkspaceHostShareRoot(),
            callerCwd: currentCallerCwd()
        )
        prepareCacheSharingIfNeeded(instanceName: targetInstanceName)
        let regResp = try daemonClient.send(RuntimeControlRequest(
            op: "session_register",
            instance: targetInstanceName,
            callerCwd: currentCallerCwd()
        ))
        guard regResp.ok, let sessionID = regResp.sessionId else {
            throw MSLRuntimeError("failed to register fallback session: \(regResp.error ?? "unknown")")
        }
        defer {
            _ = try? daemonClient.send(RuntimeControlRequest(op: "session_unregister", sessionId: sessionID))
            daemonClient.disconnect()
        }

        let execTimeoutMs: Int? = timeoutSec > 0 ? timeoutSec * 1000 : nil
        let response = try daemonClient.send(RuntimeControlRequest(
            op: "exec",
            argv: argv,
            timeoutMs: execTimeoutMs,
            runAsRoot: runAsRoot,
            sessionId: sessionID,
            cwd: execCwd,
            envAdditions: envAdditions
        ))
        if let stdout = response.stdout, !stdout.isEmpty {
            FileHandle.standardOutput.write(Data(stdout.utf8))
        }
        if let stderr = response.stderr, !stderr.isEmpty {
            FileHandle.standardError.write(Data(stderr.utf8))
        }
        let code = response.exitCode ?? (response.ok ? 0 : 1)
        if response.ok {
            logger.log("run_command_completed", fields: [
                "argv0": argv[0],
                "exit_code": String(code),
                "elapsed_ms": String(runtimeMonotonicMs() - startMs),
                "transport": "legacy_exec_fallback"
            ])
        } else {
            logger.log("run_command_error", fields: [
                "argv0": argv[0],
                "error": response.error ?? "exec failed",
                "elapsed_ms": String(runtimeMonotonicMs() - startMs),
                "transport": "legacy_exec_fallback"
            ])
        }
        Foundation.exit(code)
    }

    public func printStatus(instanceName: String? = nil, all: Bool = false) throws {
        let managerSnapshot = appManagerSnapshot()
        let state: RuntimeState = try lock.withExclusiveLock {
            try bootstrap.ensureBootstrapped(context: .runtime)
            var s = try store.loadState()
            let alive = try sessions.reconcile()
            s.activeSessionCount = alive.count
            if alive.isEmpty, s.vmState == .running, s.idleTimer.armed == false {
                let idleTimeoutMs = resolveIdleTimeoutMs()
                let deadline = nowEpochMs() + idleTimeoutMs
                s.idleTimer = IdleTimerState(armed: true, deadlineEpochMs: deadline)
                try scheduleIdleExpiry(deadlineEpochMs: deadline)
            }
            try store.saveState(s)
            logger.log("session_count_reconciled", fields: ["count": String(alive.count)])
            return s
        }

        let fallbackInstance = RuntimeInstanceState(
            instance: state.distro,
            vmState: state.vmState,
            lifecycleState: state.lifecycleState,
            activeSessionCount: state.activeSessionCount,
            idleTimer: state.idleTimer,
            runtimeUser: state.runtimeUser,
            initChannel: state.initChannel,
            runtimeHostPid: state.runtimeHostPid,
            runtimeControlSocket: state.runtimeControlSocket,
            lastError: state.lastErrorMessage,
            lastErrorCode: state.lastErrorCode,
            lastErrorMessage: state.lastErrorMessage,
            startupEpochMs: state.startupEpochMs,
            startupStep: state.startupStep,
            startupStepName: state.startupStepName,
            startupStepStatus: state.startupStepStatus,
            lastTransitionEpochMs: state.lastTransitionEpochMs
        )
        let instances = (state.instances?.isEmpty == false ? state.instances! : [fallbackInstance]).sorted {
            $0.instance < $1.instance
        }
        let managerMapped = managerSnapshot.workers.map { worker in
            RuntimeInstanceState(
                instance: worker.instanceName,
                vmState: worker.lifecycleState == .running ? .running : .stopped,
                lifecycleState: worker.lifecycleState,
                activeSessionCount: 0,
                idleTimer: IdleTimerState(),
                runtimeUser: nil,
                initChannel: nil,
                runtimeHostPid: worker.pid,
                runtimeControlSocket: worker.controlSocketPath,
                lastError: worker.lastErrorMessage,
                lastErrorCode: nil,
                lastErrorMessage: worker.lastErrorMessage,
                startupEpochMs: nil,
                startupStep: worker.startupStep,
                startupStepName: worker.startupStepName,
                startupStepStatus: nil,
                lastTransitionEpochMs: worker.lastTransitionEpochMs
            )
        }
        let statusEntries = managerMapped.isEmpty ? instances : managerMapped.sorted { $0.instance < $1.instance }

        if all {
            print("INSTANCE\tMODE\tSTATE\tLIFECYCLE\tSTEP\tSESSIONS\tIDLE\tPID\tLAST_ERROR")
            for entry in statusEntries {
                let idle = entry.idleTimer.armed ? "armed" : "not-armed"
                let pid = entry.runtimeHostPid.map(String.init) ?? "-"
                let lastError = (entry.lastErrorMessage ?? entry.lastError)?.replacingOccurrences(of: "\n", with: " ") ?? "-"
                let step = entry.startupStep.map { "\($0) \(entry.startupStepName ?? "-")" } ?? "-"
                let mode = (try? distributionManager.readOrRebuildInstanceMetadata(at: paths.distroMetadataFile(named: entry.instance)))?
                    .resolvedStartupMode()
                    .rawValue ?? DistributionInstanceMetadata.StartupMode.interactive.rawValue
                let workload = (try? distributionManager.readOrRebuildInstanceMetadata(at: paths.distroMetadataFile(named: entry.instance)))?
                    .resolvedWorkloadKind()
                    .rawValue ?? DistributionInstanceMetadata.WorkloadKind.generic.rawValue
                print("\(entry.instance)\t\(mode)/\(workload)\t\(entry.vmState.rawValue)\t\(entry.lifecycleState.rawValue)\t\(step)\t\(entry.activeSessionCount)\t\(idle)\t\(pid)\t\(lastError)")
            }
            return
        }

        let targetInstance = instanceName ?? state.distro
        guard let selected = statusEntries.first(where: { $0.instance == targetInstance }) else {
            throw MSLRuntimeError("instance '\(targetInstance)' not found")
        }
        print("instance: \(selected.instance)")
        let selectedMetadata = try distributionManager.readOrRebuildInstanceMetadata(
            at: paths.distroMetadataFile(named: selected.instance)
        )
        print("startupMode: \(selectedMetadata.resolvedStartupMode().rawValue)")
        print("workloadKind: \(selectedMetadata.resolvedWorkloadKind().rawValue)")
        print("state: \(selected.vmState.rawValue)")
        print("lifecycle: \(selected.lifecycleState.rawValue)")
        print("activeSessions: \(selected.activeSessionCount)")
        print("idleTimer: \(selected.idleTimer.armed ? "armed" : "not-armed")")
        if let step = selected.startupStep, let stepName = selected.startupStepName {
            print("startupStep: \(step) \(stepName)")
        }
        if let stepStatus = selected.startupStepStatus {
            print("startupStepStatus: \(stepStatus.rawValue)")
        }
        if let error = selected.lastErrorMessage ?? selected.lastError {
            print("lastError: \(error)")
        }
        if let code = selected.lastErrorCode {
            print("lastErrorCode: \(code)")
        }
        if let deadline = selected.idleTimer.deadlineEpochMs {
            print("idleDeadlineEpochMs: \(deadline)")
        }
        if let initChannel = selected.initChannel {
            print("initChannelStatus: \(initChannel.lastStatus.rawValue)")
            if let version = initChannel.version {
                print("initChannelVersion: \(version)")
            }
            if let lastHeartbeat = initChannel.lastHeartbeatEpochMs {
                print("initChannelLastHeartbeatEpochMs: \(lastHeartbeat)")
            }
            if let code = initChannel.lastErrorCode {
                print("initChannelLastErrorCode: \(code)")
            }
            if let message = initChannel.lastErrorMessage {
                print("initChannelLastErrorMessage: \(message)")
            }
        }
        if let line = readLastLine(paths.mslHostInitBootstrapLogFile) {
            print("initBootstrapLastLog: \(line)")
        }
    }

    public func printMemoryStatus(instanceName: String? = nil) throws {
        let target = try resolveRuntimeTarget(explicitInstanceName: instanceName)
        try lock.withExclusiveLock {
            try bootstrap.ensureBootstrapped(context: .runtime)
        }
        try daemonClient.ensureConnected(
            expectedInstanceName: target.instanceName,
            hostShareRoot: resolveWorkspaceHostShareRoot(),
            callerCwd: currentCallerCwd()
        )
        defer { daemonClient.disconnect() }

        let response = try daemonClient.send(RuntimeControlRequest(op: "memory_status"))
        guard response.ok else {
            throw MSLRuntimeError(response.error ?? "failed to fetch memory status")
        }
        guard let meta = response.meta else {
            throw MSLRuntimeError("memory status payload is empty")
        }

        func parseUInt64(_ key: String) throws -> UInt64 {
            guard let raw = meta[key], let value = UInt64(raw) else {
                throw MSLRuntimeError("memory status field '\(key)' is missing")
            }
            return value
        }

        func parseInt64Optional(_ key: String) -> Int64? {
            guard let raw = meta[key], !raw.isEmpty, let value = Int64(raw), value > 0 else {
                return nil
            }
            return value
        }

        let allocated = try parseUInt64("allocated_bytes")
        let maxMem = try parseUInt64("max_bytes")
        let returned = try parseUInt64("returned_total_bytes")
        let compactCount = try parseUInt64("compact_count")
        let dropCacheCount = try parseUInt64("drop_cache_count")
        let compactLast = parseInt64Optional("compact_last_epoch_ms")
        let dropCacheLast = parseInt64Optional("drop_cache_last_epoch_ms")

        print("instance: \(target.instanceName)")
        print("allocated: \(allocated) bytes (\(formatBytes(allocated)))")
        print("max: \(maxMem) bytes (\(formatBytes(maxMem)))")
        print("returnedTotal: \(returned) bytes (\(formatBytes(returned)))")
        print("compact: count=\(compactCount), last=\(formatEpochMs(compactLast))")
        print("dropCache: count=\(dropCacheCount), last=\(formatEpochMs(dropCacheLast))")
    }

    public func printNetworkDNSStatus(instanceName: String? = nil) throws {
        let target = try resolveRuntimeTarget(explicitInstanceName: instanceName)
        try lock.withExclusiveLock {
            try bootstrap.ensureBootstrapped(context: .runtime)
        }
        try daemonClient.ensureConnected(
            expectedInstanceName: target.instanceName,
            hostShareRoot: resolveWorkspaceHostShareRoot(),
            callerCwd: currentCallerCwd()
        )
        defer { daemonClient.disconnect() }

        let response = try daemonClient.send(RuntimeControlRequest(op: "dns_status"))
        guard response.ok else {
            throw MSLRuntimeError(response.error ?? "failed to fetch dns status")
        }
        let meta = response.meta ?? [:]
        let runtimePorts: [RuntimePortStatusItem] = (try? daemonClient.send(
            RuntimeControlRequest(op: "port_ls", instance: target.instanceName)
        ).items) ?? []
        print("instance: \(target.instanceName)")
        print("configuredNetworkMode: \(meta["configured_network_mode"] ?? ConfiguredNetworkMode.auto.rawValue)")
        print("effectiveNetworkMode: \(meta["effective_network_mode"] ?? EffectiveNetworkMode.nat.rawValue)")
        print("networkMode: \(meta["network_mode"] ?? EffectiveNetworkMode.nat.rawValue)")
        if let reason = meta["network_mode_reason"], !reason.isEmpty {
            print("networkModeReason: \(reason)")
        }
        print("sharedSubnetIPv4: \(meta["shared_subnet_ipv4"] ?? "-")")
        print("sharedSubnetMaskIPv4: \(meta["shared_subnet_mask_ipv4"] ?? "-")")
        print("guestPrivateIPv4: \(meta["guest_private_ipv4"] ?? "-")")
        print("hostGatewayIPv4: \(meta["host_gateway_ipv4"] ?? "-")")
        print("hostAlias: \(meta["host_alias"] ?? "-")")
        print("hostAliasEndpoint: \(meta["host_alias_endpoint"] ?? "-")")
        print("serviceHostname: \(meta["service_hostname"] ?? "-")")
        print("serviceHostPattern: \(meta["service_host_pattern"] ?? "-")")
        print("hostHostsStatus: \(meta["host_hosts_status"] ?? "unknown")")
        print("guestHostsStatus: \(meta["guest_hosts_status"] ?? "unknown")")
        print("dnsMode: \(meta["dns_mode"] ?? "unknown")")
        print("dnsStatus: \(meta["dns_status"] ?? "unknown")")
        print("dnsAction: \(meta["dns_action"] ?? "-")")
        print("dnsSource: \(meta["dns_source"] ?? "-")")
        print("nameservers: \(meta["nameserver_count"] ?? "0")")
        print("searchDomains: \(meta["search_domain_count"] ?? "0")")
        if let errorClass = meta["error_class"], !errorClass.isEmpty {
            print("errorClass: \(errorClass)")
        }
        if let error = meta["error"], !error.isEmpty {
            print("error: \(error)")
        }
        if let hostHostsError = meta["host_hosts_error"], !hostHostsError.isEmpty {
            print("hostHostsError: \(hostHostsError)")
        }
        if let guestHostsError = meta["guest_hosts_error"], !guestHostsError.isEmpty {
            print("guestHostsError: \(guestHostsError)")
        }
        print("")
        renderPortStatusTable(runtimePorts, manualHostPorts: [])
    }

    public func runNetworkDNSReconcile(instanceName: String? = nil) throws {
        let target = try resolveRuntimeTarget(explicitInstanceName: instanceName)
        try lock.withExclusiveLock {
            try bootstrap.ensureBootstrapped(context: .runtime)
        }
        try daemonClient.ensureConnected(
            expectedInstanceName: target.instanceName,
            hostShareRoot: resolveWorkspaceHostShareRoot(),
            callerCwd: currentCallerCwd()
        )
        defer { daemonClient.disconnect() }

        let response = try daemonClient.send(RuntimeControlRequest(op: "dns_reconcile", dnsSource: "manual"))
        guard response.ok else {
            throw MSLRuntimeError(response.error ?? "dns reconcile failed")
        }
        let meta = response.meta ?? [:]
        print("reconciled dns for \(target.instanceName)")
        print("mode=\(meta["dns_mode"] ?? "unknown") status=\(meta["dns_status"] ?? "unknown") action=\(meta["dns_action"] ?? "-")")
    }

    public func stopVM(instanceName: String? = nil, all: Bool = false) throws {
        let client = ManagerControlClient(socketPath: paths.managerSocketFile.path)
        let staleSnapshot = appManagerSnapshot()
        let target = resolveStopTargetName(explicitInstanceName: instanceName)
        if FileManager.default.fileExists(atPath: paths.managerSocketFile.path) {
            do {
                if all {
                    for worker in staleSnapshot.workers {
                        let response = try client.send(ManagerControlRequest(op: "stop_instance", instance: worker.instanceName))
                        if !response.ok {
                            throw MSLRuntimeError(response.error ?? "stop failed for \(worker.instanceName)")
                        }
                    }
                    print("stopped all")
                    return
                }
                if let target {
                    let response = try client.send(ManagerControlRequest(op: "stop_instance", instance: target))
                    if response.ok {
                        print("stopped \(target)")
                        return
                    }
                    throw MSLRuntimeError(response.error ?? "stop failed")
                }
            } catch {
                if isManagerUnavailable(error) {
                    try handleStopWithUnavailableManager(
                        explicitInstanceName: instanceName,
                        targetInstanceName: target,
                        all: all,
                        staleSnapshot: staleSnapshot
                    )
                    return
                }
                throw error
            }
        } else {
            try handleStopWithUnavailableManager(
                explicitInstanceName: instanceName,
                targetInstanceName: target,
                all: all,
                staleSnapshot: staleSnapshot
            )
            return
        }

        if all {
            print("already stopped")
            return
        }
        if let instanceName, !instanceName.isEmpty {
            throw MSLRuntimeError("instance '\(instanceName)' is not running")
        }

        // Legacy fallback: direct state manipulation
        try lock.withExclusiveLock {
            try bootstrap.ensureBootstrapped(context: .runtime)
            var state = try store.loadState()

            if state.vmState == .stopped {
                state.idleTimer = IdleTimerState(armed: false, deadlineEpochMs: nil)
                state.activeSessionCount = 0
                try store.saveState(state)
                print("already stopped")
                return
            }

            logger.log("vm_stop_requested")
            try sessions.clearAllAndTerminate()
            state.vmState = .stopped
            state.activeSessionCount = 0
            state.idleTimer = IdleTimerState(armed: false, deadlineEpochMs: nil)
            state.lastTransitionEpochMs = nowEpochMs()
            state.runtimeHostPid = nil
            state.runtimeControlSocket = nil
            try store.saveState(state)
            logger.log("vm_stopped")
            print("stopped")
        }
    }

    public func stopAppManager() throws {
        _ = try reconcileAppManagerState()

        let client = ManagerControlClient(socketPath: paths.managerSocketFile.path)
        if FileManager.default.fileExists(atPath: paths.managerSocketFile.path) {
            do {
                let response = try client.send(ManagerControlRequest(op: "stop_manager"))
                guard response.ok else {
                    throw MSLRuntimeError(response.error ?? "failed to stop app manager")
                }
                print("stopped app manager")
                return
            } catch {
                if isManagerUnavailable(error) {
                    _ = try reconcileAppManagerState()
                    print("app manager already stopped")
                    return
                }
                throw error
            }
        }

        _ = try reconcileAppManagerState()
        print("app manager already stopped")
    }

    public func addPortMapping(_ raw: String, instanceName: String? = nil) throws {
        let target = try resolveRuntimeTarget(explicitInstanceName: instanceName)
        let mapping = try parsePortMapping(raw, instanceName: target.instanceName)
        var runtimeSocket: String?
        var instanceRunning = false
        try lock.withExclusiveLock {
            try bootstrap.ensureBootstrapped(context: .runtime)
            instanceRunning = appManagerSnapshot().workers.contains(where: { $0.instanceName == target.instanceName })
            runtimeSocket = try? runtimeSocketPath(forInstance: target.instanceName)
            var state = try store.loadPortMappings()
            if let existing = state.mappings.first(where: { $0.hostPort == mapping.hostPort }) {
                if existing.instance == target.instanceName {
                    throw MSLRuntimeError("host port \(mapping.hostPort) is already mapped in instance '\(target.instanceName)'")
                }
                throw MSLRuntimeError(
                    "port_conflict host_port=\(mapping.hostPort) owner_instance=\(existing.instance)"
                )
            }
            state.mappings.append(mapping)
            state.mappings.sort { lhs, rhs in
                if lhs.hostPort == rhs.hostPort {
                    return lhs.instance < rhs.instance
                }
                return lhs.hostPort < rhs.hostPort
            }
            try store.savePortMappings(state)
            logger.log("port_forward_add", fields: [
                "instance": target.instanceName,
                "hostPort": String(mapping.hostPort),
                "guestPort": String(mapping.guestPort)
            ])
        }

        if instanceRunning {
            let socketPath = runtimeSocket ?? paths.runtimeControlSocketFile.path
            let client = RuntimeControlClient(socketPath: socketPath)
            let response = try client.send(RuntimeControlRequest(
                op: "port_add",
                instance: target.instanceName,
                hostPort: mapping.hostPort,
                guestPort: mapping.guestPort
            ))
            if !response.ok {
                throw MSLRuntimeError(response.error ?? "failed to apply runtime port mapping")
            }
        }
        print("added \(mapping.hostPort):\(mapping.guestPort) (instance=\(target.instanceName))")
    }

    public func listPortMappings(instanceName: String? = nil) throws {
        let target = try resolveRuntimeTarget(explicitInstanceName: instanceName)
        var mappings = try lock.withExclusiveLock {
            try bootstrap.ensureBootstrapped(context: .runtime)
            return try store.loadPortMappings().mappings.filter { $0.instance == target.instanceName }
        }
        let manualHostPorts = Set(mappings.map { $0.hostPort })

        let runtimeStatus: [RuntimePortStatusItem]
        if let runtimeSocketPath = try? runtimeSocketPath(forInstance: target.instanceName) {
            runtimeStatus = (try? RuntimeControlClient(socketPath: runtimeSocketPath)
                .send(RuntimeControlRequest(op: "port_ls", instance: target.instanceName, hostPort: nil, guestPort: nil)).items) ?? []
        } else {
            runtimeStatus = []
        }

        if mappings.isEmpty, runtimeStatus.isEmpty {
            print("no port mappings")
            return
        }

        // Favor runtime status when available.
        if !runtimeStatus.isEmpty {
            mappings = runtimeStatus.map {
                PortMapping(
                    hostPort: $0.hostPort,
                    guestPort: $0.guestPort,
                    bindAddress: $0.bindAddress,
                    createdAtEpochMs: nowEpochMs(),
                    instance: $0.instance ?? target.instanceName,
                    source: $0.source ?? "manual"
                )
            }
        }
        let renderedItems: [RuntimePortStatusItem]
        if !runtimeStatus.isEmpty {
            renderedItems = runtimeStatus
        } else {
            let resolvedNetworkMode = NetworkModeResolver.resolve(
                configured: NetworkModeResolver.configuredMode(from: try? defaultInstanceStore.loadConfig()),
                executablePath: executablePath
            )
            renderedItems = mappings.map { mapping in
                RuntimePortStatusItem(
                    instance: mapping.instance,
                    hostPort: mapping.hostPort,
                    guestPort: mapping.guestPort,
                    bindAddress: mapping.bindAddress,
                    source: mapping.source,
                    active: false,
                    ownerInstance: nil,
                    guestAddress: nil,
                    localhostEndpoint: "\(mapping.bindAddress):\(mapping.hostPort)",
                    hostnameEndpoint: resolvedNetworkMode.effective == .vmnetShared && mapping.bindAddress == "127.0.0.1"
                        ? "\(NetworkIdentity.serviceHostname(for: mapping.instance)):\(mapping.hostPort)"
                        : nil,
                    directEndpoint: nil,
                    error: nil
                )
            }
        }
        renderPortStatusTable(renderedItems, manualHostPorts: manualHostPorts)
    }

    public func removePortMapping(_ hostPortArg: String, instanceName: String? = nil) throws {
        guard let hostPort = Int(hostPortArg), (1...65_535).contains(hostPort) else {
            throw MSLRuntimeError("invalid host port: \(hostPortArg)")
        }

        let target = try resolveRuntimeTarget(explicitInstanceName: instanceName)
        var instanceRunning = false
        var runtimeSocket: String?
        let removed = try lock.withExclusiveLock { () throws -> Bool in
            try bootstrap.ensureBootstrapped(context: .runtime)
            instanceRunning = appManagerSnapshot().workers.contains(where: { $0.instanceName == target.instanceName })
            runtimeSocket = try? runtimeSocketPath(forInstance: target.instanceName)
            var state = try store.loadPortMappings()
            let originalCount = state.mappings.count
            state.mappings.removeAll { $0.hostPort == hostPort && $0.instance == target.instanceName }
            if state.mappings.count != originalCount {
                try store.savePortMappings(state)
                logger.log("port_forward_remove", fields: [
                    "instance": target.instanceName,
                    "hostPort": String(hostPort)
                ])
                return true
            }
            return false
        }

        if removed, instanceRunning {
            let socketPath = runtimeSocket ?? paths.runtimeControlSocketFile.path
            let client = RuntimeControlClient(socketPath: socketPath)
            let response = try client.send(RuntimeControlRequest(
                op: "port_rm",
                instance: target.instanceName,
                hostPort: hostPort,
                guestPort: nil
            ))
            if !response.ok {
                throw MSLRuntimeError(response.error ?? "failed to apply runtime port removal")
            }
        }

        if removed {
            print("removed \(hostPort) (instance=\(target.instanceName))")
        } else {
            print("no mapping for host port \(hostPort) in instance \(target.instanceName)")
        }
    }

    // Keep runInitExec for backward-compat with --_init-exec
    public func runInitExec(argv: [String], timeoutMs: Int = 1_000) throws -> Int32 {
        guard !argv.isEmpty else {
            throw MSLRuntimeError("init exec requires at least one argv element")
        }
        logger.log("init_command_exec_started", fields: [
            "op": "exec",
            "argv0": argv[0]
        ])
        let startMs = runtimeMonotonicMs()
        let client = InitChannelClient(
            socketPath: paths.initChannelSocketFile.path,
            handoffPath: paths.initChannelHandoffFile.path,
            ackPath: paths.initChannelAckFile.path,
            retryCount: 3,
            retryDelayMs: 100,
            timeoutMs: timeoutMs
        )
        let response = try client.send(InitChannelRequest(op: "exec", argv: argv, timeoutMs: timeoutMs))

        let elapsed = runtimeMonotonicMs() - startMs
        if response.ok {
            if let stdout = response.stdout, !stdout.isEmpty {
                let line = stdout.hasSuffix("\n") ? stdout : stdout + "\n"
                FileHandle.standardOutput.write(Data(line.utf8))
            }
            if let stderr = response.stderr, !stderr.isEmpty {
                let line = stderr.hasSuffix("\n") ? stderr : stderr + "\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
            logger.log("init_command_exec_finished", fields: [
                "op": "exec",
                "duration_ms": String(elapsed),
                "exit_code": String(response.exitCode ?? 0)
            ])
            return response.exitCode ?? 0
        }

        let code = response.error?.code.rawValue ?? InitChannelErrorCode.internalError.rawValue
        let message = response.error?.message ?? "init exec failed"
        if code == InitChannelErrorCode.timeout.rawValue {
            logger.log("init_command_exec_timeout", fields: [
                "op": "exec",
                "duration_ms": String(elapsed)
            ])
        } else {
            logger.log("init_command_exec_finished", fields: [
                "op": "exec",
                "duration_ms": String(elapsed),
                "error_code": code
            ])
        }
        throw MSLRuntimeError(
            "init exec failed (\(code)): \(message). " +
            "verify msl-init is running and handoff files are reachable at " +
            "\(paths.initChannelHandoffFile.path) / \(paths.initChannelAckFile.path)"
        )
    }

    public func handleIdleExpiry(deadlineEpochMs: Int64) throws {
        let waitMs = deadlineEpochMs - nowEpochMs()
        if waitMs > 0 {
            usleep(useconds_t(waitMs * 1000))
        }

        try lock.withExclusiveLock {
            try bootstrap.ensureBootstrapped(context: .runtime)
            var state = try store.loadState()
            let alive = try sessions.reconcile()
            state.activeSessionCount = alive.count

            guard state.vmState == .running else {
                return
            }
            guard state.idleTimer.armed, state.idleTimer.deadlineEpochMs == deadlineEpochMs else {
                return
            }
            guard alive.isEmpty else {
                state.idleTimer = IdleTimerState(armed: false, deadlineEpochMs: nil)
                try store.saveState(state)
                return
            }

            state.vmState = .stopped
            state.idleTimer = IdleTimerState(armed: false, deadlineEpochMs: nil)
            state.lastTransitionEpochMs = nowEpochMs()
            try store.saveState(state)
            logger.log("idle_timer_expired", fields: ["deadline": String(deadlineEpochMs)])
            logger.log("vm_stopped", fields: ["reason": "idle_timeout"])
        }
    }

    // MARK: - Shell Helpers

    private var savedTermios: termios?

    private func currentWindowSize() -> (rows: Int?, cols: Int?) {
        var size = winsize()
        if ioctl(FileHandle.standardOutput.fileDescriptor, TIOCGWINSZ, &size) == 0 {
            return (Int(size.ws_row), Int(size.ws_col))
        }
        if ioctl(FileHandle.standardInput.fileDescriptor, TIOCGWINSZ, &size) == 0 {
            return (Int(size.ws_row), Int(size.ws_col))
        }
        return (nil, nil)
    }

    private func hostHasOutputTTY() -> Bool {
        isatty(FileHandle.standardOutput.fileDescriptor) == 1 &&
        isatty(FileHandle.standardError.fileDescriptor) == 1
    }

    private func hostHasInteractiveTTY() -> Bool {
        isatty(FileHandle.standardInput.fileDescriptor) == 1 && hostHasOutputTTY()
    }

    private func nerdctlEnvironment() -> [String: String] {
        var env = [
            "CONTAINERD_ADDRESS": "/run/containerd/containerd.sock",
            "BUILDKIT_HOST": "unix:///run/buildkit/buildkitd.sock",
            "CONTAINERD_SNAPSHOTTER": "native",
            "TERM": ProcessInfo.processInfo.environment["TERM"].flatMap { $0.isEmpty ? nil : $0 } ?? "xterm-256color"
        ]
        if let colorTerm = ProcessInfo.processInfo.environment["COLORTERM"], !colorTerm.isEmpty {
            env["COLORTERM"] = colorTerm
        }
        return env
    }

    private func applyDefaultNerdctlSnapshotterIfNeeded(_ argv: [String]) -> [String] {
        guard !nerdctlArgumentsSpecifySnapshotter(argv) else {
            return argv
        }
        return ["--snapshotter", "native"] + argv
    }

    private func nerdctlArgumentsSpecifySnapshotter(_ argv: [String]) -> Bool {
        var index = 0
        while index < argv.count {
            let arg = argv[index]
            if arg == "--" {
                return false
            }
            if arg == "--snapshotter" || arg.hasPrefix("--snapshotter=") {
                return true
            }
            if arg.hasPrefix("-"), !arg.contains("="), index + 1 < argv.count,
               ["-n", "--namespace", "--address", "--cgroup-manager", "--data-root", "--host"].contains(arg) {
                index += 2
            } else {
                index += 1
            }
        }
        return false
    }

    private func resolveNerdctlTerminalMode(argv: [String]) -> NerdctlTerminalMode {
        guard hostHasOutputTTY() else { return .streamingProc }
        if nerdctlHasInteractiveTTYFlag(argv: argv) {
            return hostHasInteractiveTTY() ? .interactivePTY : .displayPTY
        }
        return nerdctlNeedsDisplayPTY(argv: argv) ? .displayPTY : .streamingProc
    }

    private func resolveNerdctlTerminalModeForExecution(argv: [String]) throws -> NerdctlTerminalMode {
        if nerdctlNeedsConfirmationPrompt(argv: argv) && !nerdctlHasForceFlag(argv: argv) {
            guard hostHasInteractiveTTY() else {
                throw MSLRuntimeError("nerdctl prune requires an interactive terminal; rerun with --force to skip confirmation")
            }
            return .interactivePTY
        }
        return resolveNerdctlTerminalMode(argv: argv)
    }

    private func nerdctlHasInteractiveTTYFlag(argv: [String]) -> Bool {
        argv.contains { arg in
            arg == "-i" || arg == "-t" || arg == "-it" || arg == "-ti"
                || arg == "--interactive" || arg == "--tty"
        }
    }

    private func nerdctlNeedsDisplayPTY(argv: [String]) -> Bool {
        let commandIndex = firstNerdctlCommandIndex(in: argv)
        let command = commandIndex.map { argv[$0] }
        switch command {
        case "run", "pull", "push", "build":
            return true
        case "compose":
            guard let commandIndex,
                  let composeCommandIndex = firstNerdctlCommandIndex(in: Array(argv.dropFirst(commandIndex + 1))) else {
                return false
            }
            let composeCommand = Array(argv.dropFirst(commandIndex + 1))[composeCommandIndex]
            return composeCommand == "up" || composeCommand == "build" || composeCommand == "pull"
        default:
            return false
        }
    }

    private func nerdctlNeedsConfirmationPrompt(argv: [String]) -> Bool {
        guard let commandIndex = firstNerdctlCommandIndex(in: argv) else {
            return false
        }
        let command = argv[commandIndex]
        if command == "system" {
            let remaining = Array(argv.dropFirst(commandIndex + 1))
            return firstNerdctlCommandIndex(in: remaining).map { remaining[$0] } == "prune"
        }
        if ["container", "image", "network", "volume"].contains(command) {
            let remaining = Array(argv.dropFirst(commandIndex + 1))
            return firstNerdctlCommandIndex(in: remaining).map { remaining[$0] } == "prune"
        }
        return command == "prune"
    }

    private func nerdctlHasForceFlag(argv: [String]) -> Bool {
        argv.contains { token in
            token == "-f" || token == "--force" || token.hasPrefix("--force=")
        }
    }

    private func nerdctlNeedsBuildkit(argv: [String]) -> Bool {
        guard let commandIndex = firstNerdctlCommandIndex(in: argv) else {
            return false
        }
        let command = argv[commandIndex]
        if command == "build" || command == "builder" {
            return true
        }
        if command == "compose" {
            let rest = Array(argv.dropFirst(commandIndex + 1))
            guard let composeCommandIndex = firstNerdctlCommandIndex(in: rest) else {
                return false
            }
            let composeCommand = rest[composeCommandIndex]
            return composeCommand == "build" || composeCommand == "up"
        }
        return false
    }

    private func firstNerdctlCommandIndex(in argv: [String]) -> Int? {
        var index = 0
        while index < argv.count {
            let arg = argv[index]
            if arg == "--" {
                index += 1
                continue
            }
            if arg.hasPrefix("-") {
                if ["--namespace", "--address", "--snapshotter", "--cgroup-manager", "--data-root", "--host", "--file", "-n", "-f"].contains(arg),
                   index + 1 < argv.count {
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            return index
        }
        return nil
    }

    private func enterRawModeForShell() {
        let fd = FileHandle.standardInput.fileDescriptor
        guard isatty(fd) == 1 else { return }
        var term = termios()
        guard tcgetattr(fd, &term) == 0 else { return }
        savedTermios = term
        var raw = term
        cfmakeraw(&raw)
        _ = tcsetattr(fd, TCSAFLUSH, &raw)
    }

    private func isDaemonAlive(pid: Int32) -> Bool {
        if pid <= 0 { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    private func appManagerSnapshot() -> AppManagerState {
        (try? appManagerStateStore.load()) ?? .initial(nowMs: nowEpochMs())
    }

    @discardableResult
    private func reconcileAppManagerState() throws -> AppManagerStateReconciliationResult {
        try appManagerStateStore.reconcile(pingManager: { [paths] in
            let client = ManagerControlClient(socketPath: paths.managerSocketFile.path)
            guard let response = try? client.send(ManagerControlRequest(op: "app_ping")) else {
                return false
            }
            return response.ok
        })
    }

    private func runtimeSocketPath(forInstance instanceName: String) throws -> String {
        if let worker = appManagerSnapshot().workers.first(where: { $0.instanceName == instanceName }) {
            return worker.controlSocketPath
        }
        throw MSLRuntimeError("instance '\(instanceName)' is not running")
    }

    private func resolveStopTargetName(explicitInstanceName: String?) -> String? {
        if let explicitInstanceName,
           !explicitInstanceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return explicitInstanceName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let configured = (try? defaultInstanceStore.loadDefaultInstanceName()) ?? nil,
           !configured.isEmpty {
            return configured
        }
        return nil
    }

    private func handleStopWithUnavailableManager(
        explicitInstanceName: String?,
        targetInstanceName: String?,
        all: Bool,
        staleSnapshot: AppManagerState
    ) throws {
        let reconciliation = try reconcileAppManagerState()
        if all {
            if staleSnapshot.workers.isEmpty && !reconciliation.hadTrackedWorkers {
                print("already stopped")
            } else {
                print("stopped all")
            }
            return
        }

        if let explicitInstanceName,
           !explicitInstanceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let explicit = explicitInstanceName.trimmingCharacters(in: .whitespacesAndNewlines)
            if reconciliation.trackedWorker(instanceName: explicit)
                || staleSnapshot.workers.contains(where: { $0.instanceName == explicit }) {
                print("stopped \(explicit)")
                return
            }
            if distributionManager.instanceExists(named: explicit) {
                throw MSLRuntimeError("instance '\(explicit)' is not running")
            }
            throw MSLRuntimeError("instance '\(explicit)' not found")
        }

        if let targetInstanceName,
           (reconciliation.trackedWorker(instanceName: targetInstanceName)
                || staleSnapshot.workers.contains(where: { $0.instanceName == targetInstanceName })) {
            print("stopped \(targetInstanceName)")
            return
        }

        print("already stopped")
    }

    private func isManagerUnavailable(_ error: Error) -> Bool {
        if let posix = error as? POSIXError {
            switch posix.code {
            case .ECONNREFUSED, .ENOENT, .ENOTSOCK, .ECONNABORTED, .ECONNRESET:
                return true
            default:
                break
            }
        }
        let description = String(describing: error).lowercased()
        return description.contains("connection refused")
            || description.contains("no such file or directory")
            || description.contains("not a socket")
            || description.contains("socket is not connected")
    }

    func shouldTerminateInteractiveShellAttach(for error: Error?) -> Bool {
        if hasInteractiveShellAttachStateEnded() {
            return true
        }
        guard let error else {
            return false
        }
        return Self.isInteractiveShellAttachDisconnectError(String(describing: error))
    }

    func hasInteractiveShellAttachStateEnded() -> Bool {
        let snapshot = appManagerSnapshot()
        if let worker = snapshot.workers.first {
            if !isDaemonAlive(pid: worker.pid) {
                return true
            }
            let socketPath = worker.controlSocketPath
            if !socketPath.isEmpty, !fileManager.fileExists(atPath: socketPath) {
                return true
            }
            return false
        }
        guard let state = try? lock.withExclusiveLock(timeoutSec: 1, { try store.loadState() }) else {
            return true
        }
        let daemonPid = state.daemonHostPid ?? state.runtimeHostPid
        guard let daemonPid else {
            return true
        }
        if !isDaemonAlive(pid: daemonPid) {
            return true
        }
        let socketPath = state.daemonControlSocket ?? state.runtimeControlSocket ?? ""
        if !socketPath.isEmpty, !fileManager.fileExists(atPath: socketPath) {
            return true
        }
        return false
    }

    static func isInteractiveShellAttachDisconnectError(_ description: String) -> Bool {
        let normalized = description.lowercased()
        let needles = [
            "broken pipe",
            "connection refused",
            "connection reset",
            "connection aborted",
            "socket is not connected",
            "not connected to daemon",
            "no such file or directory"
        ]
        return needles.contains { normalized.contains($0) }
    }

    // MARK: - Legacy (serial-console / direct attach)

    private func runAttachedSession() -> Int32 {
        if ProcessInfo.processInfo.environment["MSL_FORCE_LOCAL_SHELL"] == "1" {
            return runLocalShell()
        }

        do {
            let target = try resolveRuntimeTarget(explicitInstanceName: nil)
            let runner = VirtualMachineRunner(
                paths: paths,
                metadataURL: target.metadataURL,
                logger: logger,
                initProbeHandler: { [weak self] probe in
                    self?.updateInitChannelState(probe)
                },
                networkMode: NetworkModeResolver.resolve(
                    configured: NetworkModeResolver.configuredMode(from: try? defaultInstanceStore.loadConfig()),
                    executablePath: executablePath
                ).effective
            )
            return try runner.runAttachedConsole()
        } catch {
            fputs("msl: VM attach failed: \(error)\n", stderr)
            fputs("msl: tip: use MSL_FORCE_LOCAL_SHELL=1 to debug lifecycle without VM backend.\n", stderr)
            return 1
        }
    }

    private func runLocalShell() -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-il"]
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            fputs("failed to start local shell: \(error)\n", stderr)
            return 1
        }
    }

    private func scheduleIdleExpiry(deadlineEpochMs: Int64) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["--_idle-expire", String(deadlineEpochMs)]
        process.standardInput = nil
        process.standardOutput = nil
        process.standardError = nil
        try process.run()
        process.terminationHandler = { _ in }
        logger.log("idle_timer_dispatched", fields: ["deadline": String(deadlineEpochMs)])
    }

    /// Returns the idle timeout in milliseconds.
    /// Give newly booted runtimes a longer initial idle window before enabling
    /// the normal short shutdown timeout.
    private func resolveIdleTimeoutMs() -> Int64 {
        if let raw = ProcessInfo.processInfo.environment["MSL_IDLE_TIMEOUT_MS"],
           let val = Int64(raw), val > 0 {
            return val
        }
        if !FileManager.default.fileExists(atPath: paths.mslHostInitBootstrapLogFile.path) {
            return 300_000
        }
        return 10_000
    }

    private func updateInitChannelState(_ probe: InitChannelProbeResult) {
        do {
            try lock.withExclusiveLock(timeoutSec: 1) {
                var state = try store.loadState()
                state.initChannel = InitChannelState(
                    version: probe.version,
                    lastHeartbeatEpochMs: nowEpochMs(),
                    lastStatus: probe.status,
                    lastErrorCode: probe.errorCode,
                    lastErrorMessage: probe.errorMessage
                )
                try store.saveState(state)
            }
        } catch {
            logger.log("init_channel_state_update_failed", fields: ["error": String(describing: error)])
        }
    }

    private func logInitBootstrapTail() {
        if let line = readLastLine(paths.mslHostInitBootstrapLogFile) {
            logger.log("init_bootstrap_log_seen", fields: ["line": line])
        }
    }

    private func readLastLine(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        guard let last = text.split(separator: "\n").last else {
            return nil
        }
        return String(last)
    }

    private func parsePortMapping(_ raw: String, instanceName: String) throws -> PortMapping {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw MSLRuntimeError("invalid mapping '\(raw)'. expected <hostPort>:<guestPort>")
        }
        guard let hostPort = Int(parts[0]), let guestPort = Int(parts[1]) else {
            throw MSLRuntimeError("invalid mapping '\(raw)'. ports must be integers")
        }
        guard (1...65_535).contains(hostPort), (1...65_535).contains(guestPort) else {
            throw MSLRuntimeError("invalid mapping '\(raw)'. ports must be in 1..65535")
        }
        return PortMapping(hostPort: hostPort, guestPort: guestPort, instance: instanceName)
    }

    private func renderPortStatusTable(_ items: [RuntimePortStatusItem], manualHostPorts: Set<Int>) {
        if items.isEmpty {
            print("no port mappings")
            return
        }
        print("INSTANCE\tHOST\tGUEST\tBIND\tSOURCE\tSTATE\tLOCALHOST\tDIRECT\tHOSTNAME\tDETAIL")
        for item in items.sorted(by: {
            ($0.instance ?? "", $0.hostPort, $0.guestPort) < ($1.instance ?? "", $1.hostPort, $1.guestPort)
        }) {
            let source = item.source ?? (manualHostPorts.contains(item.hostPort) ? "manual" : "auto")
            let status = item.active ? "active" : "inactive"
            let localhost = item.localhostEndpoint ?? "\(item.bindAddress):\(item.hostPort)"
            let direct = item.directEndpoint ?? "-"
            let hostname = item.hostnameEndpoint ?? "-"
            let detail = item.error?.replacingOccurrences(of: "\n", with: " ") ?? "-"
            print("\(item.instance ?? "-")\t\(item.hostPort)\t\(item.guestPort)\t\(item.bindAddress)\t\(source)\t\(status)\t\(localhost)\t\(direct)\t\(hostname)\t\(detail)")
        }
    }

    private func isInstanceRunning(_ state: RuntimeState, instanceName: String) -> Bool {
        if state.distro == instanceName, state.vmState == .running {
            return true
        }
        return state.instances?.contains(where: { $0.instance == instanceName && $0.vmState == .running }) == true
    }

    private func currentCallerCwd() -> String {
        return URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private static func resolveExecutablePath(_ rawPath: String, fileManager: FileManager) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return rawPath
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL.path
        }
        if trimmed.contains("/") {
            let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            return URL(fileURLWithPath: trimmed, relativeTo: cwd)
                .standardizedFileURL
                .path
        }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = String(dir) + "/" + trimmed
                if fileManager.isExecutableFile(atPath: candidate) {
                    return URL(fileURLWithPath: candidate).standardizedFileURL.path
                }
            }
        }
        return rawPath
    }

    private struct WorkspaceStartupPolicyDecision {
        var workspaceGuestPath: String?
        var overlays: [WorkspaceExcludeOverlay]

        static let disabled = WorkspaceStartupPolicyDecision(workspaceGuestPath: nil, overlays: [])
    }

    private func evaluateWorkspaceStartupPolicy(instanceName: String, metadataURL: URL) -> WorkspaceStartupPolicyDecision {
        do {
            let metadata = try distributionManager.readInstanceMetadata(at: metadataURL)
            let launchDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            let resolver = WorkspaceActivationResolver(fileManager: fileManager)
            switch try resolver.resolve(launchDirectory: launchDirectory, workspacePolicy: metadata.workspacePolicy) {
            case .disabled(let reason):
                if reason == "startup_mount_disabled" {
                    logger.log("startup_mount_skipped", fields: [
                        "instance": instanceName,
                        "metadata": metadataURL.path,
                        "reason": reason
                    ])
                } else if reason == "workspace_config_missing" {
                    logger.log("mslconfig_missing", fields: [
                        "instance": instanceName,
                        "cwd": launchDirectory.path
                    ])
                } else if reason == "workspace_protected_path" || reason == "workspace_permission_denied" {
                    logger.log("workspace_fallback_home", fields: [
                        "instance": instanceName,
                        "cwd": launchDirectory.path,
                        "reason": reason
                    ])
                } else {
                    logger.log("workspace_resolve_failed", fields: [
                        "instance": instanceName,
                        "reason": reason
                    ])
                }
                return .disabled
            case .enabled(let config, let workspaceGuestPath):
                let sharedRoot = resolveWorkspaceHostShareRoot()
                if !WorkspaceHostSharePolicy.isPathAllowed(workspaceGuestPath, withinRoot: sharedRoot) {
                    logger.log("workspace_fallback_home", fields: [
                        "instance": instanceName,
                        "cwd": launchDirectory.path,
                        "workspace_guest_path": workspaceGuestPath,
                        "shared_root": sharedRoot,
                        "reason": "workspace_outside_shared_root"
                    ])
                    return .disabled
                }
                logger.log("mslconfig_loaded", fields: [
                    "instance": instanceName,
                    "cwd": launchDirectory.path,
                    "workspace_guest_path": workspaceGuestPath,
                    "exclude_count": String(config.excludes.count)
                ])
                let overlays = try WorkspaceExcludePlanner().plan(
                    workspaceGuestPath: workspaceGuestPath,
                    excludes: config.excludes
                )
                logger.log("mount_plan_built", fields: [
                    "instance": instanceName,
                    "workspace_guest_path": workspaceGuestPath,
                    "exclude_overlay_count": String(overlays.count)
                ])
                return WorkspaceStartupPolicyDecision(
                    workspaceGuestPath: workspaceGuestPath,
                    overlays: overlays
                )
            }
        } catch let parseError as WorkspaceConfigParseError {
            logger.log("mslconfig_invalid", fields: [
                "instance": instanceName,
                "metadata": metadataURL.path,
                "error": parseError.description
            ])
            logger.log("workspace_fallback_home", fields: [
                "instance": instanceName,
                "reason": "mslconfig_invalid"
            ])
            return .disabled
        } catch {
            logger.log("workspace_resolve_failed", fields: [
                "instance": instanceName,
                "metadata": metadataURL.path,
                "error": String(describing: error)
            ])
            return .disabled
        }
    }

    private func evaluateNerdctlWorkspacePolicy(
        instanceName: String,
        metadataURL: URL,
        metadata: DistributionInstanceMetadata
    ) -> WorkspaceStartupPolicyDecision {
        let resolved = evaluateWorkspaceStartupPolicy(instanceName: instanceName, metadataURL: metadataURL)
        if resolved.workspaceGuestPath != nil {
            return resolved
        }
        guard metadata.resolvedWorkloadKind() == .containerRuntime else {
            return resolved
        }

        let launchDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let resolvedPath = launchDirectory.resolvingSymlinksInPath().path
        let hostShareRoot = resolveWorkspaceHostShareRoot()
        guard WorkspaceHostSharePolicy.isPathAllowed(resolvedPath, withinRoot: hostShareRoot) else {
            return resolved
        }
        let protectedPrefixes = metadata.workspacePolicy?.protectedGuestPathPrefixes ?? WorkspaceActivationResolver.defaultProtectedGuestPathPrefixes
        for prefix in protectedPrefixes {
            let normalized = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.isEmpty || !normalized.hasPrefix("/") {
                continue
            }
            if resolvedPath == normalized || resolvedPath.hasPrefix(normalized + "/") {
                return resolved
            }
        }

        logger.log("workspace_runtime_fallback_enabled", fields: [
            "instance": instanceName,
            "cwd": resolvedPath,
            "reason": "container_runtime_direct_mount"
        ])
        return WorkspaceStartupPolicyDecision(workspaceGuestPath: resolvedPath, overlays: [])
    }

    private func resolveWorkspaceHostShareRoot() -> String {
        let config = try? defaultInstanceStore.loadConfig()
        return WorkspaceHostSharePolicy.resolveRoot(
            config: config,
            environment: ProcessInfo.processInfo.environment,
            fileManager: fileManager
        )
    }

    private func prepareCacheSharingIfNeeded(instanceName: String) {
        do {
            let response = try daemonClient.send(RuntimeControlRequest(op: "cache_share_prepare"))
            if response.ok {
                logger.log("cache_share_prepare_started", fields: [
                    "instance": instanceName,
                    "status": response.meta?["status"] ?? "applied",
                    "reason": response.meta?["reason"] ?? "-"
                ])
            } else {
                logger.log("cache_share_fallback_local", fields: [
                    "instance": instanceName,
                    "reason": "daemon_error",
                    "error": response.error ?? "unknown"
                ])
            }
        } catch {
            logger.log("cache_share_fallback_local", fields: [
                "instance": instanceName,
                "reason": "daemon_request_error",
                "error": String(describing: error)
            ])
        }
    }

    private func prepareWorkspaceIfNeeded(
        policy: WorkspaceStartupPolicyDecision,
        instanceName: String
    ) -> String? {
        guard let workspaceGuestPath = policy.workspaceGuestPath else {
            return nil
        }
        let hostShareRoot = resolveWorkspaceHostShareRoot()

        do {
            let response = try daemonClient.send(RuntimeControlRequest(
                op: "workspace_prepare",
                timeoutMs: 4_000,
                cwd: workspaceGuestPath,
                hostShareRoot: hostShareRoot
            ))
            guard response.ok else {
                logger.log("workspace_fallback_home", fields: [
                    "instance": instanceName,
                    "workspace_guest_path": workspaceGuestPath,
                    "reason": "workspace_prepare_failed",
                    "error": response.error ?? "unknown"
                ])
                return nil
            }
            logger.log("workspace_resolve_succeeded", fields: [
                "instance": instanceName,
                "workspace_guest_path": workspaceGuestPath,
                "exclude_overlay_count": String(policy.overlays.count),
                "mount_status": response.meta?["status"] ?? "applied"
            ])
            return workspaceGuestPath
        } catch {
            logger.log("workspace_fallback_home", fields: [
                "instance": instanceName,
                "workspace_guest_path": workspaceGuestPath,
                "reason": "workspace_prepare_error",
                "error": String(describing: error)
            ])
            return nil
        }
    }

    private func prepareDirectWorkspaceIfNeeded(
        client: InitChannelClient,
        policy: WorkspaceStartupPolicyDecision,
        instanceName: String
    ) throws -> String? {
        guard let workspaceGuestPath = policy.workspaceGuestPath else {
            return nil
        }
        let hostShareRoot = resolveWorkspaceHostShareRoot()

        let response = try client.send(InitChannelRequest(
            op: "host_share_prepare",
            cwd: workspaceGuestPath,
            hostShareRoot: hostShareRoot,
            timeoutMs: 4_000
        ))
        guard response.ok else {
            logger.log("workspace_fallback_home", fields: [
                "instance": instanceName,
                "workspace_guest_path": workspaceGuestPath,
                "reason": "direct_workspace_prepare_failed",
                "error": response.error?.message ?? "unknown"
            ])
            return nil
        }
        logger.log("workspace_resolve_succeeded", fields: [
            "instance": instanceName,
            "workspace_guest_path": workspaceGuestPath,
            "exclude_overlay_count": String(policy.overlays.count),
            "mount_status": response.meta?["status"] ?? "applied"
        ])
        return workspaceGuestPath
    }

    private func resolveRuntimeTarget(explicitInstanceName: String?) throws -> (instanceName: String, metadataURL: URL) {
        let configured = try defaultInstanceStore.loadDefaultInstanceName()
        let metadataURL = try distributionManager.runtimeMetadataURL(
            explicitInstanceName: explicitInstanceName,
            defaultInstanceName: configured
        )
        let instanceName = metadataURL.deletingLastPathComponent().lastPathComponent
        return (instanceName, metadataURL)
    }

    private func resolveContainerRuntimeTarget(explicitInstanceName: String?) throws -> (instanceName: String, metadataURL: URL) {
        let trimmedExplicit = explicitInstanceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = (trimmedExplicit?.isEmpty == false)
            ? trimmedExplicit!
            : distributionManager.resolveContainerRuntimeInstanceName()
        let metadataURL = paths.distroMetadataFile(named: resolvedName)
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            throw MSLRuntimeError("container runtime artifact is not installed; use `make build-container-runtime`")
        }
        let metadata = try distributionManager.readOrRebuildInstanceMetadata(at: metadataURL)
        guard metadata.source.sourceType == "container-runtime" else {
            throw MSLRuntimeError("instance '\(resolvedName)' is not a container runtime instance")
        }
        if metadata.resolvedRootMode() == .readonlyBaseCowState {
            let baseURL = URL(fileURLWithPath: metadata.baseDiskPath ?? paths.distroBaseDiskFile(named: resolvedName).path)
            let stateURL = URL(fileURLWithPath: metadata.stateDiskPath ?? paths.distroStateDiskFile(named: resolvedName).path)
            guard fileManager.fileExists(atPath: baseURL.path), fileManager.fileExists(atPath: stateURL.path) else {
                throw MSLRuntimeError("container runtime split artifact is incomplete; use `make build-container-runtime`")
            }
        } else {
            let diskURL = paths.distroDiskFile(named: resolvedName)
            guard fileManager.fileExists(atPath: diskURL.path) else {
                throw MSLRuntimeError("container runtime artifact is not installed; use `make build-container-runtime`")
            }
            throw MSLRuntimeError("container runtime uses legacy disk.raw storage; use `make build-container-runtime` to rebuild resettable storage")
        }
        return (resolvedName, metadataURL)
    }

    struct NerdctlWorkspacePlan: Equatable {
        var requiresWorkspace: Bool
    }

    enum NerdctlPrimaryCommand: Equatable {
        case build
        case compose
        case other(String?)
    }

    func resolveNerdctlWorkspacePlan(argv: [String]) throws -> NerdctlWorkspacePlan {
        let command = try parseNerdctlPrimaryCommand(argv: argv)
        switch command {
        case .build:
            try validateNerdctlBuildArguments(argv)
            return NerdctlWorkspacePlan(requiresWorkspace: true)
        case .compose:
            try validateNerdctlComposeArguments(argv)
            return NerdctlWorkspacePlan(requiresWorkspace: true)
        default:
            return NerdctlWorkspacePlan(requiresWorkspace: false)
        }
    }

    func parseNerdctlPrimaryCommand(argv: [String]) throws -> NerdctlPrimaryCommand {
        switch try Self.parseNerdctlPrimaryCommandForPorts(argv: argv) {
        case "build":
            return .build
        case "compose":
            return .compose
        case let command:
            return .other(command)
        }
    }

    static func parseNerdctlPrimaryCommandForPorts(argv: [String]) throws -> String? {
        let globalOptionsWithValues: Set<String> = [
            "--address", "-a",
            "--namespace", "-n",
            "--host", "-H",
            "--snapshotter",
            "--data-root",
            "--cni-path",
            "--cni-netconfpath"
        ]
        var index = 0
        while index < argv.count {
            let token = argv[index]
            if token == "--" {
                break
            }
            if globalOptionsWithValues.contains(token) {
                index += 2
                continue
            }
            if token.hasPrefix("-") {
                index += 1
                continue
            }
            return token
        }
        return nil
    }

    private func validateNerdctlBuildArguments(_ argv: [String]) throws {
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true).resolvingSymlinksInPath()
        let hostShareRoot = resolveWorkspaceHostShareRoot()
        var dockerfilePath: String?
        var contextPath: String?
        var seenBuild = false
        var expectDockerfileValue = false

        for token in argv {
            if expectDockerfileValue {
                dockerfilePath = token
                expectDockerfileValue = false
                continue
            }
            if !seenBuild {
                if token == "build" {
                    seenBuild = true
                }
                continue
            }
            if token == "--" { continue }
            if token == "-f" || token == "--file" {
                expectDockerfileValue = true
                continue
            }
            if token.hasPrefix("--file=") {
                dockerfilePath = String(token.dropFirst("--file=".count))
                continue
            }
            if token.hasPrefix("-") {
                continue
            }
            contextPath = token
        }

        if let dockerfilePath {
            try validateNerdctlWorkspacePathArgument(
                dockerfilePath,
                cwd: cwd,
                hostShareRoot: hostShareRoot,
                label: "Dockerfile path"
            )
        }
        if let contextPath {
            try validateNerdctlWorkspacePathArgument(
                contextPath,
                cwd: cwd,
                hostShareRoot: hostShareRoot,
                label: "build context"
            )
        }
    }

    private func validateNerdctlComposeArguments(_ argv: [String]) throws {
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true).resolvingSymlinksInPath()
        let hostShareRoot = resolveWorkspaceHostShareRoot()
        var seenCompose = false
        var expectFileValue = false

        for token in argv {
            if expectFileValue {
                try validateNerdctlWorkspacePathArgument(
                    token,
                    cwd: cwd,
                    hostShareRoot: hostShareRoot,
                    label: "compose file"
                )
                expectFileValue = false
                continue
            }
            if !seenCompose {
                if token == "compose" {
                    seenCompose = true
                }
                continue
            }
            if token == "-f" || token == "--file" {
                expectFileValue = true
                continue
            }
            if token.hasPrefix("--file=") {
                try validateNerdctlWorkspacePathArgument(
                    String(token.dropFirst("--file=".count)),
                    cwd: cwd,
                    hostShareRoot: hostShareRoot,
                    label: "compose file"
                )
            }
        }
    }

    private func validateNerdctlWorkspacePathArgument(
        _ rawPath: String,
        cwd: URL,
        hostShareRoot: String,
        label: String
    ) throws {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let resolved: URL
        if trimmed.hasPrefix("/") {
            resolved = URL(fileURLWithPath: trimmed, isDirectory: false).resolvingSymlinksInPath()
        } else {
            resolved = cwd.appendingPathComponent(trimmed).resolvingSymlinksInPath()
        }
        let resolvedPath = resolved.path
        let cwdPath = cwd.path
        guard resolvedPath == cwdPath || resolvedPath.hasPrefix(cwdPath + "/") else {
            throw MSLRuntimeError("\(label) must stay within the current workspace: \(trimmed)")
        }
        guard WorkspaceHostSharePolicy.isPathAllowed(cwdPath, withinRoot: hostShareRoot) else {
            throw MSLRuntimeError("current workspace is outside workspace host share root")
        }
    }

    private func shouldForceRootRuntimeUser() -> Bool {
        guard let raw = ProcessInfo.processInfo.environment["MSL_RUNTIME_USER_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else {
            return false
        }
        return raw == "1" || raw == "true" || raw == "yes"
    }

    private func isInstanceRunningByName(_ instanceName: String) throws -> Bool {
        try lock.withExclusiveLock {
            try bootstrap.ensureBootstrapped(context: .runtime)
            let state = try store.loadState()
            return isInstanceRunning(state, instanceName: instanceName)
        }
    }

    private func runtimeInstanceStateByName(_ instanceName: String) throws -> RuntimeInstanceState? {
        try lock.withExclusiveLock {
            try bootstrap.ensureBootstrapped(context: .runtime)
            let state = try store.loadState()
            if let matched = state.instances?.first(where: { $0.instance == instanceName }) {
                return matched
            }
            if state.distro == instanceName {
                return RuntimeInstanceState(
                    instance: state.distro,
                    vmState: state.vmState,
                    activeSessionCount: state.activeSessionCount,
                    idleTimer: state.idleTimer,
                    runtimeUser: state.runtimeUser,
                    initChannel: state.initChannel,
                    runtimeHostPid: state.runtimeHostPid,
                    runtimeControlSocket: state.runtimeControlSocket,
                    lastError: nil,
                    lastTransitionEpochMs: state.lastTransitionEpochMs
                )
            }
            return nil
        }
    }

    private func shouldAutoStopBeforeImageScan(instanceName: String) throws -> Bool {
        guard let instance = try runtimeInstanceStateByName(instanceName) else {
            return false
        }
        guard instance.vmState == .running else {
            return false
        }
        // Only auto-stop when no interactive session is attached.
        // If sessions are active, scan should keep the existing explicit failure behavior.
        return instance.activeSessionCount == 0
    }

    private func mapHostPathToGuestVisible(_ hostPath: String, hostShareRoot: String) -> String? {
        guard hostPath.hasPrefix("/") else {
            return nil
        }
        let normalizedRoot = hostShareRoot.hasSuffix("/") && hostShareRoot.count > 1
            ? String(hostShareRoot.dropLast())
            : hostShareRoot
        if normalizedRoot == "/" {
            return "/mnt/macos" + hostPath
        }
        if hostPath == normalizedRoot {
            return "/mnt/macos"
        }
        if hostPath.hasPrefix(normalizedRoot + "/") {
            let suffix = String(hostPath.dropFirst(normalizedRoot.count))
            return "/mnt/macos" + suffix
        }
        return nil
    }

    private func guestVisibleHostPathCandidates(_ hostPath: String, hostShareRoot: String) -> [String] {
        guard hostPath.hasPrefix("/") else {
            return []
        }
        var candidates: [String] = []
        if let mapped = mapHostPathToGuestVisible(hostPath, hostShareRoot: hostShareRoot) {
            candidates.append(mapped)
        }
        if hostShareRoot != "/" {
            if !candidates.contains(hostPath) {
                candidates.append(hostPath)
            }
        }
        return candidates
    }

    private func isInitSourceMissing(response: RuntimeControlResponse) -> Bool {
        if response.exitCode == 20 {
            return true
        }
        if let error = response.error?.lowercased(), error.contains("source_missing") {
            return true
        }
        if let stderr = response.stderr?.lowercased(), stderr.contains("source_missing") {
            return true
        }
        return false
    }

    private func defaultImageExportOutputPath(mode: String, instanceName: String) -> String {
        let fileName: String
        switch mode {
        case "archive":
            fileName = "\(instanceName).zstd"
        case "rootfs":
            fileName = "\(instanceName).rootfs.tar.xz"
        default:
            fileName = "\(instanceName).img"
        }
        return URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
            .path
    }

    private func logicalBytes(of fileURL: URL) -> Int64? {
        do {
            let attrs = try fileManager.attributesOfItem(atPath: fileURL.path)
            if let value = attrs[.size] as? NSNumber {
                return value.int64Value
            }
            return nil
        } catch {
            return nil
        }
    }

    private func allocatedBytes(of fileURL: URL) -> Int64? {
        let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        if let total = values?.totalFileAllocatedSize {
            return Int64(total)
        }
        if let allocated = values?.fileAllocatedSize {
            return Int64(allocated)
        }
        return nil
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func runHostShell(_ command: String) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-lc", command]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
    private func formatBytes(_ bytes: UInt64) -> String {
        let gib = Double(bytes) / Double(1024 * 1024 * 1024)
        return String(format: "%.2f GiB", gib)
    }

    private struct GuestStorageInspectStats {
        var beforeCompressionBytes: Int64?
        var afterCompressionBytes: Int64?
        var compressionRatioPercent: Double?
        var tmpTotalBytes: Int64?
        var tmpUsedBytes: Int64?
        var tmpAvailBytes: Int64?
        var tmpUsePercent: Int64?
        var varTmpTotalBytes: Int64?
        var varTmpUsedBytes: Int64?
        var varTmpAvailBytes: Int64?
        var varTmpUsePercent: Int64?
    }

    private struct ExternalizedCacheUsage {
        var label: String
        var hostPath: String
        var bytes: Int64
    }

    private func collectGuestStorageInspectStatsIfRunning(instanceName: String) throws -> GuestStorageInspectStats? {
        if try !isInstanceRunningByName(instanceName) {
            return nil
        }
        let hostShareRoot = resolveWorkspaceHostShareRoot()
        try daemonClient.ensureConnected(
            expectedInstanceName: instanceName,
            hostShareRoot: hostShareRoot,
            callerCwd: currentCallerCwd()
        )
        defer {
            daemonClient.disconnect()
        }
        let response = try daemonClient.send(RuntimeControlRequest(
            op: "exec",
            instance: instanceName,
            argv: [
                "/bin/sh",
                "-lc",
                """
                set -eu
                emit_df() {
                  path="$1"
                  prefix="$2"
                  line="$(df -kP "$path" 2>/dev/null | awk 'NR==2 {print $2\" \"$3\" \"$4\" \"$5}' || true)"
                  [ -n "$line" ] || return 0
                  set -- $line
                  total_kib="$1"
                  used_kib="$2"
                  avail_kib="$3"
                  use_pct="${4%%%}"
                  case "$total_kib" in ''|*[!0-9]*) total_kib='' ;; esac
                  case "$used_kib" in ''|*[!0-9]*) used_kib='' ;; esac
                  case "$avail_kib" in ''|*[!0-9]*) avail_kib='' ;; esac
                  case "$use_pct" in ''|*[!0-9]*) use_pct='' ;; esac
                  if [ -n "$total_kib" ]; then echo "${prefix}_total_bytes=$((total_kib * 1024))"; fi
                  if [ -n "$used_kib" ]; then echo "${prefix}_used_bytes=$((used_kib * 1024))"; fi
                  if [ -n "$avail_kib" ]; then echo "${prefix}_avail_bytes=$((avail_kib * 1024))"; fi
                  if [ -n "$use_pct" ]; then echo "${prefix}_use_percent=$use_pct"; fi
                }
                if command -v du >/dev/null 2>&1; then
                  apparent_kib="$(du -sx --apparent-size / 2>/dev/null | awk '{print $1}' || true)"
                  actual_kib="$(du -sx / 2>/dev/null | awk '{print $1}' || true)"
                  case "$apparent_kib" in ''|*[!0-9]*) apparent_kib='' ;; esac
                  case "$actual_kib" in ''|*[!0-9]*) actual_kib='' ;; esac
                  if [ -n "$apparent_kib" ]; then
                    echo "du_apparent_bytes=$((apparent_kib * 1024))"
                  fi
                  if [ -n "$actual_kib" ]; then
                    echo "du_actual_bytes=$((actual_kib * 1024))"
                  fi
                fi
                emit_df /tmp tmp
                emit_df /var/tmp var_tmp
                """
            ],
            timeoutMs: 120_000
        ))
        guard response.ok, (response.exitCode ?? 1) == 0 else {
            return nil
        }
        let parsed = parseKeyValueLines(response.stdout ?? "")
        let beforeCompressionBytes = parsed["du_apparent_bytes"]
        let afterCompressionBytes = parsed["du_actual_bytes"]
        let ratio: Double?
        if let beforeCompressionBytes, let afterCompressionBytes, beforeCompressionBytes > 0 {
            ratio = (1.0 - (Double(afterCompressionBytes) / Double(beforeCompressionBytes))) * 100.0
        } else {
            ratio = nil
        }
        logger.log("image_inspect_tmp_usage_collected", fields: [
            "instance": instanceName,
            "tmp_used_bytes": parsed["tmp_used_bytes"].map(String.init) ?? "",
            "var_tmp_used_bytes": parsed["var_tmp_used_bytes"].map(String.init) ?? ""
        ])
        return GuestStorageInspectStats(
            beforeCompressionBytes: beforeCompressionBytes,
            afterCompressionBytes: afterCompressionBytes,
            compressionRatioPercent: ratio,
            tmpTotalBytes: parsed["tmp_total_bytes"],
            tmpUsedBytes: parsed["tmp_used_bytes"],
            tmpAvailBytes: parsed["tmp_avail_bytes"],
            tmpUsePercent: parsed["tmp_use_percent"],
            varTmpTotalBytes: parsed["var_tmp_total_bytes"],
            varTmpUsedBytes: parsed["var_tmp_used_bytes"],
            varTmpAvailBytes: parsed["var_tmp_avail_bytes"],
            varTmpUsePercent: parsed["var_tmp_use_percent"]
        )
    }

    private func parseKeyValueLines(_ text: String) -> [String: Int64] {
        var result: [String: Int64] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let valueText = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, let value = Int64(valueText) else { continue }
            result[key] = value
        }
        return result
    }

    private func collectExternalizedCacheUsages(metadata: DistributionInstanceMetadata) -> [ExternalizedCacheUsage] {
        let policyConfig = metadata.cacheSharing ?? CacheSharingPolicyResolver.defaultConfigForDistroFamily(
            metadata.distroFamily
                ?? metadata.source.distro
                ?? DistributionManager.inferDistroFamilyStatic(from: metadata.source.manifestId)
        )
        let policy = CacheSharingPolicyResolver.resolve(config: policyConfig)
        guard policy.enabled else {
            return []
        }

        let hostHome = ProcessInfo.processInfo.environment["HOME"] ?? fileManager.homeDirectoryForCurrentUser.path
        let hostCacheRoot = CacheSharingPolicyResolver.hostCacheRootPath(hostHome: hostHome)
        var candidates: [(String, String)] = []
        if policy.apt { candidates.append(("apt", hostCacheRoot + "/apt")) }
        if policy.apk { candidates.append(("apk", hostCacheRoot + "/apk")) }
        if policy.zypper { candidates.append(("zypper", hostCacheRoot + "/zypper")) }
        if policy.dnf { candidates.append(("dnf", hostCacheRoot + "/dnf")) }
        if policy.go { candidates.append(("go", hostCacheRoot + "/go")) }
        if policy.python { candidates.append(("python", hostCacheRoot + "/python")) }
        if policy.npm { candidates.append(("npm", hostCacheRoot + "/node/npm")) }
        if policy.pnpm { candidates.append(("pnpm", hostCacheRoot + "/node/pnpm-store")) }
        if policy.yarn { candidates.append(("yarn", hostCacheRoot + "/node/yarn")) }
        if policy.maven { candidates.append(("maven", hostCacheRoot + "/java/maven-repo")) }
        if policy.gradle { candidates.append(("gradle", hostCacheRoot + "/java/gradle")) }
        if policy.composer { candidates.append(("composer", hostCacheRoot + "/php/composer")) }
        if policy.scala { candidates.append(("scala", hostCacheRoot + "/scala")) }
        if policy.ruby { candidates.append(("ruby", hostCacheRoot + "/ruby")) }
        if policy.rust { candidates.append(("rust", hostCacheRoot + "/rust")) }
        if policy.deno { candidates.append(("deno", hostCacheRoot + "/deno")) }
        if policy.bun { candidates.append(("bun", hostCacheRoot + "/bun")) }
        if policy.nuget { candidates.append(("nuget", hostCacheRoot + "/dotnet")) }

        return candidates.map { label, path in
            let bytes = hostDirectoryUsageBytes(path: path) ?? 0
            return ExternalizedCacheUsage(label: label, hostPath: path, bytes: bytes)
        }
    }

    private func hostDirectoryUsageBytes(path: String) -> Int64? {
        let quoted = shellQuote(path)
        let result = try? runHostShell("du -sk \(quoted) 2>/dev/null | awk '{print $1}'")
        guard let result, result.exitCode == 0 else {
            return nil
        }
        let raw = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let kib = Int64(raw), kib >= 0 else {
            return nil
        }
        return kib * 1024
    }

    private func copyLocalFileToRemote(localURL: URL, remotePath: String, instanceName: String) throws {
        let inputHandle = try FileHandle(forReadingFrom: localURL)
        defer { try? inputHandle.close() }
        let command = makeRemoteFileUploadCommand(
            localBaseName: localURL.lastPathComponent,
            remotePath: remotePath
        )
        _ = try runRemoteProc(
            instanceName: instanceName,
            argv: ["/bin/sh", "-lc", command],
            inputFD: inputHandle.fileDescriptor,
            attachInput: true
        )
    }

    private func copyRemoteFileToLocal(remotePath: String, localPath: String, instanceName: String) throws {
        let targetURL = try resolveLocalFileDownloadTarget(remotePath: remotePath, localPath: localPath)
        let tempURL = makeTemporarySiblingURL(for: targetURL)
        fileManager.createFile(atPath: tempURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: tempURL)
        var outputError: Error?
        do {
            let result = try runRemoteProc(
                instanceName: instanceName,
                argv: ["/bin/sh", "-lc", makeRemoteFileDownloadCommand(remotePath: remotePath)],
                inputFD: nil,
                attachInput: false,
                onOutput: { event in
                    switch event.kind {
                    case .stdout:
                        do {
                            try outputHandle.write(contentsOf: event.data)
                        } catch {
                            outputError = error
                            return false
                        }
                    case .stderr:
                        break
                    }
                    return true
                }
            )
            try outputHandle.close()
            if let outputError {
                throw outputError
            }
            try replaceItem(at: targetURL, with: tempURL)
            if result.exitCode != 0 {
                throw MSLRuntimeError(result.stderr.isEmpty ? "copy failed" : result.stderr, exitCode: result.exitCode)
            }
        } catch {
            try? outputHandle.close()
            try? fileManager.removeItem(at: tempURL)
            throw error
        }
    }

    private func copyLocalDirectoryToRemote(localURL: URL, remotePath: String, instanceName: String) throws {
        let tar = try hostTarExecutable()
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tar)
        process.arguments = ["-C", localURL.deletingLastPathComponent().path, "-cf", "-", localURL.lastPathComponent]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        defer {
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
        }

        do {
            _ = try runRemoteProc(
                instanceName: instanceName,
                argv: ["/bin/sh", "-lc", makeRemoteDirectoryUploadCommand(localBaseName: localURL.lastPathComponent, remotePath: remotePath)],
                inputFD: stdoutPipe.fileHandleForReading.fileDescriptor,
                attachInput: true
            )
            process.waitUntilExit()
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard process.terminationStatus == 0 else {
                throw MSLRuntimeError(stderr.isEmpty ? "host tar failed" : stderr, exitCode: process.terminationStatus)
            }
        } catch {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            throw error
        }
    }

    private func copyRemoteDirectoryToLocal(remotePath: String, localPath: String, instanceName: String) throws {
        let tar = try hostTarExecutable()
        let extraction = try prepareLocalDirectoryExtraction(remotePath: remotePath, localPath: localPath)
        let process = Process()
        let stdinPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tar)
        process.arguments = ["-xf", "-", "-C", extraction.extractRoot.path]
        process.standardInput = stdinPipe
        process.standardError = stderrPipe
        try process.run()

        do {
            _ = try runRemoteProc(
                instanceName: instanceName,
                argv: ["/bin/sh", "-lc", makeRemoteDirectoryDownloadCommand(remotePath: remotePath)],
                inputFD: nil,
                attachInput: false,
                onOutput: { event in
                    switch event.kind {
                    case .stdout:
                        do {
                            try stdinPipe.fileHandleForWriting.write(contentsOf: event.data)
                        } catch {
                            return false
                        }
                    case .stderr:
                        break
                    }
                    return true
                }
            )
            try stdinPipe.fileHandleForWriting.close()
            process.waitUntilExit()
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard process.terminationStatus == 0 else {
                throw MSLRuntimeError(stderr.isEmpty ? "host tar extract failed" : stderr, exitCode: process.terminationStatus)
            }
            try finalizeLocalDirectoryExtraction(extraction)
        } catch {
            try? stdinPipe.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            try? cleanupLocalDirectoryExtraction(extraction)
            throw error
        }
    }

    private struct RemoteProcResult {
        var exitCode: Int32
        var stdout: String
        var stderr: String
    }

    private func runRemoteProc(
        instanceName: String,
        argv: [String],
        inputFD: Int32?,
        attachInput: Bool,
        onOutput: ((ProcOutputEvent) -> Bool)? = nil
    ) throws -> RemoteProcResult {
        try lock.withExclusiveLock {
            try bootstrap.ensureBootstrapped(context: .runtime)
        }

        try daemonClient.ensureConnected(
            expectedInstanceName: instanceName,
            hostShareRoot: resolveWorkspaceHostShareRoot(),
            callerCwd: currentCallerCwd()
        )

        let regResp = try daemonClient.send(RuntimeControlRequest(
            op: "session_register",
            instance: instanceName,
            callerCwd: currentCallerCwd()
        ))
        guard regResp.ok, let sessionID = regResp.sessionId else {
            throw MSLRuntimeError("failed to register session: \(regResp.error ?? "unknown")")
        }
        defer {
            _ = try? daemonClient.send(RuntimeControlRequest(op: "session_unregister", sessionId: sessionID))
            daemonClient.disconnect()
        }

        let openResp = try daemonClient.send(RuntimeControlRequest(
            op: "proc_open",
            argv: argv,
            runAsRoot: shouldForceRootRuntimeUser(),
            sessionId: sessionID
        ))
        guard openResp.ok, let procId = openResp.procId else {
            throw MSLRuntimeError(openResp.error ?? "proc_open failed")
        }
        defer {
            _ = try? daemonClient.send(RuntimeControlRequest(op: "proc_close", procId: procId, sessionId: sessionID))
        }

        var stdout = Data()
        var stderr = Data()
        let result = try SessionStreamBridge.runProc(
            daemonClient: daemonClient,
            procID: procId,
            sessionID: sessionID,
            inputFD: inputFD,
            attachInput: attachInput,
            onOutput: { event in
                if let onOutput {
                    return onOutput(event)
                }
                switch event.kind {
                case .stdout:
                    stdout.append(event.data)
                case .stderr:
                    stderr.append(event.data)
                }
                return true
            }
        )
        let stdoutText = String(data: stdout, encoding: .utf8) ?? ""
        let stderrText = String(data: stderr, encoding: .utf8) ?? ""
        if result.exitCode != 0 {
            let message = stderrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
                : stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MSLRuntimeError(message.isEmpty ? "remote copy command failed" : message, exitCode: result.exitCode)
        }
        return RemoteProcResult(exitCode: result.exitCode, stdout: stdoutText, stderr: stderrText)
    }

    private func hostTarExecutable() throws -> String {
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/tar") {
            return "/usr/bin/tar"
        }
        let process = ProcessExecutor()
        if let found = process.findExecutable(["tar"]) {
            return found
        }
        throw MSLRuntimeError("tar not found")
    }

    func makeRemoteFileUploadCommand(localBaseName: String, remotePath: String) -> String {
        let remote = remotePathShellExpression(remotePath)
        let base = shellQuote(localBaseName)
        return "dest=\(remote); base=\(base); if [ -d \"$dest\" ]; then dest=\"$dest/$base\"; fi; exec cat > \"$dest\""
    }

    func makeRemoteFileDownloadCommand(remotePath: String) -> String {
        let remote = remotePathShellExpression(remotePath)
        return "src=\(remote); if [ -d \"$src\" ]; then echo \"omitting directory '$src'; use -r to copy directories\" >&2; exit 1; fi; exec cat < \"$src\""
    }

    func makeRemoteDirectoryUploadCommand(localBaseName: String, remotePath: String) -> String {
        let remote = remotePathShellExpression(remotePath)
        let base = shellQuote(localBaseName)
        return """
        dest=\(remote); src_base=\(base); \
        if [ -d "$dest" ]; then exec tar -xf - -C "$dest"; fi; \
        if [ -e "$dest" ]; then echo "destination exists and is not a directory: $dest" >&2; exit 1; fi; \
        tmp=$(mktemp -d "${TMPDIR:-/tmp}/msl-cp.XXXXXX"); trap 'rm -rf "$tmp"' EXIT INT TERM; \
        tar -xf - -C "$tmp" || exit $?; \
        if [ ! -e "$tmp/$src_base" ]; then echo "archive missing expected root: $src_base" >&2; exit 1; fi; \
        mv "$tmp/$src_base" "$dest"
        """
    }

    func makeRemoteDirectoryDownloadCommand(remotePath: String) -> String {
        let remote = remotePathShellExpression(remotePath)
        return "src=\(remote); if [ ! -d \"$src\" ]; then echo \"not a directory: $src\" >&2; exit 1; fi; parent=$(dirname \"$src\"); base=$(basename \"$src\"); exec tar -cf - -C \"$parent\" \"$base\""
    }

    func resolveLocalFileDownloadTarget(remotePath: String, localPath: String) throws -> URL {
        let expandedLocalPath = try expandLocalCopyPath(localPath)
        let localURL = URL(fileURLWithPath: expandedLocalPath)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: localURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return localURL.appendingPathComponent(URL(fileURLWithPath: remotePath).lastPathComponent, isDirectory: false)
        }
        return localURL
    }

    private struct LocalDirectoryExtractionPlan {
        var extractRoot: URL
        var tempRoot: URL?
        var finalTarget: URL
        var expectedExtractedName: String
        var replaceDirectly: Bool
    }

    private func prepareLocalDirectoryExtraction(remotePath: String, localPath: String) throws -> LocalDirectoryExtractionPlan {
        let remoteBase = URL(fileURLWithPath: remotePath).lastPathComponent
        let expandedLocalPath = try expandLocalCopyPath(localPath)
        let localURL = URL(fileURLWithPath: expandedLocalPath)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: localURL.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                return .init(
                    extractRoot: localURL,
                    tempRoot: nil,
                    finalTarget: localURL.appendingPathComponent(remoteBase, isDirectory: true),
                    expectedExtractedName: remoteBase,
                    replaceDirectly: false
                )
            }
            throw MSLRuntimeError("destination exists and is not a directory: \(localPath)")
        }

        let parent = localURL.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory), parentIsDirectory.boolValue else {
            throw MSLRuntimeError("destination parent does not exist: \(parent.path)")
        }
        let tempRoot = parent.appendingPathComponent(".msl-cp-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: false)
        return .init(
            extractRoot: tempRoot,
            tempRoot: tempRoot,
            finalTarget: localURL,
            expectedExtractedName: remoteBase,
            replaceDirectly: true
        )
    }

    private func finalizeLocalDirectoryExtraction(_ plan: LocalDirectoryExtractionPlan) throws {
        guard plan.replaceDirectly, let tempRoot = plan.tempRoot else {
            return
        }
        let extracted = tempRoot.appendingPathComponent(plan.expectedExtractedName, isDirectory: true)
        let sourceURL: URL
        if fileManager.fileExists(atPath: extracted.path) {
            sourceURL = extracted
        } else {
            let children = try fileManager.contentsOfDirectory(at: tempRoot, includingPropertiesForKeys: nil)
            guard children.count == 1 else {
                throw MSLRuntimeError("archive missing expected root: \(plan.expectedExtractedName)")
            }
            sourceURL = children[0]
        }
        try replaceItem(at: plan.finalTarget, with: sourceURL)
        try? fileManager.removeItem(at: tempRoot)
    }

    private func cleanupLocalDirectoryExtraction(_ plan: LocalDirectoryExtractionPlan) throws {
        if let tempRoot = plan.tempRoot {
            try? fileManager.removeItem(at: tempRoot)
        }
    }

    private func replaceItem(at destination: URL, with source: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: source, to: destination)
    }

    private func makeTemporarySiblingURL(for target: URL) -> URL {
        let parent = target.deletingLastPathComponent()
        return parent.appendingPathComponent(".msl-cp-\(UUID().uuidString).tmp", isDirectory: false)
    }

    func expandLocalCopyPath(_ raw: String) throws -> String {
        try MSLCopyPathParser.expandLocalPath(raw)
    }

    func remotePathShellExpression(_ raw: String) -> String {
        if raw == "~" {
            return "\"$HOME\""
        }
        if raw.hasPrefix("~/") {
            let suffix = String(raw.dropFirst(2))
            if suffix.isEmpty {
                return "\"$HOME\""
            }
            return "\"$HOME\"/\(shellQuote(suffix))"
        }
        if !raw.hasPrefix("/") {
            return "\"$HOME\"/\(shellQuote(raw))"
        }
        return shellQuote(raw)
    }

    private func formatMegaBytesTenths(_ bytes: Int64) -> String {
        let mb = Double(max(0, bytes)) / Double(1024 * 1024)
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: mb)) ?? String(format: "%.1f", mb)
    }

    private func printIndentedMegaBytesLine(label: String, bytes: Int64?) {
        let labelWidth = 24
        let valueWidth = 10
        let paddedLabel = label.padding(toLength: labelWidth, withPad: " ", startingAt: 0)
        guard let bytes else {
            let paddedValue = "N/A".leftPadding(toLength: valueWidth)
            print("  \(paddedLabel)\(paddedValue) MB")
            return
        }
        let value = formatMegaBytesTenths(bytes)
        let paddedValue = value.leftPadding(toLength: valueWidth)
        print("  \(paddedLabel)\(paddedValue) MB")
    }

    private func printIndentedCompressedLine(label: String, bytes: Int64?, savingPercent: Double?) {
        let labelWidth = 24
        let valueWidth = 10
        let paddedLabel = label.padding(toLength: labelWidth, withPad: " ", startingAt: 0)
        guard let bytes else {
            let paddedValue = "N/A".leftPadding(toLength: valueWidth)
            print("  \(paddedLabel)\(paddedValue) MB")
            return
        }
        let size = formatMegaBytesTenths(bytes).leftPadding(toLength: valueWidth)
        if let savingPercent {
            let percent = String(format: "-%.1f%%", savingPercent)
            print("  \(paddedLabel)\(size) MB (\(percent))")
        } else {
            print("  \(paddedLabel)\(size) MB")
        }
    }

    private func printPathUsageLine(
        label: String,
        totalBytes: Int64?,
        usedBytes: Int64?,
        availBytes: Int64?,
        usePercent: Int64?
    ) {
        guard
            let totalBytes,
            let usedBytes,
            let availBytes,
            let usePercent
        else {
            print("  \(label) unavailable")
            return
        }
        let total = formatMegaBytesTenths(totalBytes).leftPadding(toLength: 10)
        let used = formatMegaBytesTenths(usedBytes).leftPadding(toLength: 10)
        let avail = formatMegaBytesTenths(availBytes).leftPadding(toLength: 10)
        print("  \(label) total=\(total)MB used=\(used)MB avail=\(avail)MB use%=\(usePercent)")
    }

    private func formatDefragTimestamp(_ maintenance: DistributionInstanceMetadata.ImageMaintenanceStatus?) -> String {
        guard let maintenance else { return "never" }
        if maintenance.lastOperation == "manual_defrag" || maintenance.lastOperation == "startup_auto_trim" {
            return formatEpochMs(maintenance.lastRunAtEpochMs)
        }
        if let compactAt = maintenance.lastCompactAtEpochMs {
            return formatEpochMs(compactAt)
        }
        return "never"
    }

    private func tildePath(_ path: String) -> String {
        let homePath = fileManager.homeDirectoryForCurrentUser.path
        if path == homePath {
            return "~"
        }
        if path.hasPrefix(homePath + "/") {
            return "~" + String(path.dropFirst(homePath.count))
        }
        return path
    }
    private func formatEpochMs(_ value: Int64?) -> String {
        guard let value else {
            return "never"
        }
        let date = Date(timeIntervalSince1970: TimeInterval(value) / 1000.0)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return "\(formatter.string(from: date)) (\(value))"
    }
}

private func runtimeMonotonicMs() -> Int64 {
    Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
}

private extension String {
    func leftPadding(toLength length: Int, withPad pad: Character = " ") -> String {
        guard count < length else { return self }
        return String(repeating: String(pad), count: length - count) + self
    }
}
