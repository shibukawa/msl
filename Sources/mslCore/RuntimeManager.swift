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
    private let paths: MSLPaths
    private let fileManager: FileManager
    private let lock: FileLock
    private let store: StateStore
    private let bootstrap: BootstrapManager
    private let sessions: SessionManager
    private let logger: MSLLogger
    private let executablePath: String
    private let defaultInstanceStore: DefaultInstanceStore

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
        if let homeOverride = ProcessInfo.processInfo.environment["MSL_HOME"], !homeOverride.isEmpty {
            self.paths = MSLPaths(homeDirectoryURL: URL(fileURLWithPath: homeOverride))
        } else {
            self.paths = MSLPaths(fileManager: fileManager)
        }

        try fileManager.createDirectory(at: paths.runtime, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.appLogs, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.distrosDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.cacheDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.cacheDownloadsDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.cacheStagingDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.kernelsDir, withIntermediateDirectories: true)

        self.logger = MSLLogger(logFile: paths.logs.appendingPathComponent("msl.log", isDirectory: false), fileManager: fileManager)
        self.lock = try FileLock(path: paths.lockFile.path)
        self.store = StateStore(paths: paths, fileManager: fileManager)
        self.bootstrap = BootstrapManager(paths: paths, logger: logger, fileManager: fileManager)
        self.sessions = SessionManager(store: store)
        self.executablePath = RuntimeManager.resolveExecutablePath(executablePath, fileManager: fileManager)
        self.defaultInstanceStore = DefaultInstanceStore(paths: paths, fileManager: fileManager)

        do {
            try distributionManager.migrateLegacyRootfsCacheIfNeeded()
        } catch {
            logger.log("cache_layout_migration_failed", fields: [
                "error": String(describing: error)
            ])
        }
    }

    public func runInitWorkspace(force: Bool) throws -> Never {
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            .resolvingSymlinksInPath()
        let result = try WorkspaceConfigInitializer(fileManager: fileManager).createConfig(in: cwd, force: force)
        let sharedRoot = resolveWorkspaceHostShareRoot()
        if result.overwritten {
            print("workspace config updated: \(result.configFile.path)")
        } else {
            print("workspace config created: \(result.configFile.path)")
        }
        if !WorkspaceHostSharePolicy.isPathAllowed(cwd.path, withinRoot: sharedRoot) {
            print("warning: \(cwd.path) is outside workspace host share root (\(sharedRoot)).")
            print("workspace mirror will fallback to home until you update: \(paths.configFile.path)")
            print("add/adjust `workspaceHostShareRoot` to include this folder (example: \"\(cwd.deletingLastPathComponent().path)\").")
        }
        Foundation.exit(0)
    }

    public func runSetConfig(path rawPath: String, value rawValue: String) throws -> Never {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)

        let prefix = "storageCacheToggles."
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
                "unsupported config key '\(path)'. supported: storageCacheToggles.<name>, network.dns.mode, network.dns.manualNameservers, network.dns.manualSearchDomains"
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
        rebuild: Bool,
        diskSizeGB: Int?
    ) throws -> Never {
        // Internal bootstrap instance must stay on legacy path to avoid recursion.
        if name == "_imagewriter" {
            try runBootstrapInstall(
                name: name,
                targetAlias: targetAlias,
                localFilePath: localFilePath,
                rebuild: rebuild,
                diskSizeGB: diskSizeGB
            )
        }

        try bootstrap.ensureBootstrapped(context: .install)

        let dir = try distributionManager.createImageWithImagewriter(
            name: name,
            targetAlias: targetAlias,
            localFilePath: localFilePath,
            rebuild: rebuild,
            diskSizeGB: diskSizeGB,
            mslExecutablePath: executablePath
        )

        try finalizeDefaultInstanceAndKernelIfNeeded(installedName: name)
        print("image created: \(dir.path)")
        Foundation.exit(0)
    }

    public func runBootstrapInstall(
        name: String,
        targetAlias: String?,
        localFilePath: String?,
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
        if name == "_imagewriter" {
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

    public func listInstalledInstances() throws -> Never {
        let instances = distributionManager
            .installedInstances()
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
                throw MSLRuntimeError("instance '\(name)' is running. run `msl --stop` first.")
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

    public func runDefaultShell(instanceName: String? = nil) throws -> Never {
        let commandStartMs = runtimeMonotonicMs()
        let metadataResolveStartMs = runtimeMonotonicMs()
        let target = try resolveRuntimeTarget(explicitInstanceName: instanceName)
        logger.log("startup_phase_duration_ms", fields: [
            "phase": "runtime_metadata_resolve",
            "elapsed_ms": String(max(0, runtimeMonotonicMs() - metadataResolveStartMs)),
            "instance": target.instanceName
        ])
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

        // IO pump loop
        let stdinFD = FileHandle.standardInput.fileDescriptor
        var exitCode: Int32 = 0
        var stdinOpen = true
        var sawOutput = false
        var consecutiveErrors = 0
        let maxConsecutiveErrors = 50
        var idleCount = 0
        var lastRows = size.rows
        var lastCols = size.cols

        while true {
            // Check window size changes
            let currentSize = currentWindowSize()
            if let r = currentSize.rows, let c = currentSize.cols,
               r != lastRows || c != lastCols {
                _ = try? daemonClient.send(RuntimeControlRequest(
                    op: "pty_resize",
                    ptyId: ptyId,
                    rows: r,
                    cols: c,
                    sessionId: sessionID
                ))
                lastRows = r
                lastCols = c
            }

            // Poll stdin
            let stdinPollMs: Int32
            if idleCount <= 2 {
                stdinPollMs = 30
            } else if idleCount <= 10 {
                stdinPollMs = 100
            } else {
                stdinPollMs = 250
            }

            if stdinOpen {
                var fds = [pollfd(fd: stdinFD, events: Int16(POLLIN), revents: 0)]
                let ready = poll(&fds, 1, stdinPollMs)
                if ready > 0, (fds[0].revents & Int16(POLLIN)) != 0 {
                    var buffer = [UInt8](repeating: 0, count: 8192)
                    let bytesRead = read(stdinFD, &buffer, buffer.count)
                    if bytesRead == 0 {
                        stdinOpen = false
                    } else if bytesRead > 0 {
                        // Check for detach key (Ctrl-])
                        if let idx = buffer[..<bytesRead].firstIndex(of: 0x1d) {
                            if idx > 0 {
                                let data = Data(buffer[..<idx])
                                _ = try? daemonClient.send(RuntimeControlRequest(
                                    op: "pty_write",
                                    ptyId: ptyId,
                                    dataBase64: data.base64EncodedString(),
                                    sessionId: sessionID
                                ))
                            }
                            exitCode = 0
                            break
                        }

                        let data = Data(buffer[..<bytesRead])
                        do {
                            _ = try daemonClient.send(RuntimeControlRequest(
                                op: "pty_write",
                                ptyId: ptyId,
                                dataBase64: data.base64EncodedString(),
                                sessionId: sessionID
                            ))
                            consecutiveErrors = 0
                            idleCount = 0
                        } catch {
                            consecutiveErrors += 1
                            if consecutiveErrors >= maxConsecutiveErrors { break }
                            Thread.sleep(forTimeInterval: 0.5)
                            continue
                        }
                    }
                }
            }

            // Read PTY output
            do {
                let readResp = try daemonClient.send(RuntimeControlRequest(
                    op: "pty_read",
                    timeoutMs: 1_000,
                    ptyId: ptyId,
                    sessionId: sessionID
                ))
                guard readResp.ok else {
                    let errMsg = readResp.error ?? "pty_read failed"
                    throw MSLRuntimeError(errMsg)
                }
                consecutiveErrors = 0

                let hasOutput: Bool
                if let payload = readResp.dataBase64, let out = Data(base64Encoded: payload), !out.isEmpty {
                    FileHandle.standardOutput.write(out)
                    hasOutput = true
                    idleCount = 0
                    if !sawOutput { sawOutput = true }
                } else {
                    hasOutput = false
                    idleCount += 1
                }

                if let code = readResp.exitCode {
                    exitCode = code
                    break
                }
                if let exitRaw = readResp.meta?["exitCode"], let code = Int32(exitRaw) {
                    exitCode = code
                    break
                }

                if !hasOutput {
                    let sleepSec = min(0.05 + Double(idleCount) * 0.02, 0.5)
                    Thread.sleep(forTimeInterval: sleepSec)
                }
            } catch {
                consecutiveErrors += 1
                let desc = String(describing: error)
                let isTransient = desc.contains("timeout") || desc.contains("poll failed")
                if isTransient && consecutiveErrors < maxConsecutiveErrors {
                    let backoff = min(0.5 * pow(2.0, Double(consecutiveErrors - 1)), 5.0)
                    Thread.sleep(forTimeInterval: backoff)
                    continue
                }
                break
            }
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

    /// Run the daemon process (entry point for `msl --_daemon`).
    public func runDaemon(instanceName: String? = nil) throws -> Never {
        let daemon = try DaemonServer(executablePath: executablePath, explicitInstanceName: instanceName)
        try daemon.run()
    }

    /// Run `msl provision`: wait for cloud-init to complete.
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

        // Poll provision_status
        fputs("msl: waiting for provisioning (cloud-init)... (Ctrl+C to cancel)\n", stderr)
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSec))
        var pollCount = 0
        while Date() < deadline {
            if isInterrupted() {
                fputs("\nmsl: provisioning interrupted by user\n", stderr)
                Foundation.exit(130)
            }
            pollCount += 1
            let resp = try daemonClient.send(RuntimeControlRequest(op: "provision_status", sessionId: sessionID))
            if resp.ok {
                let cloudInit = resp.meta?["cloud_init"] ?? "unknown"
                logger.log("provision_polling", fields: [
                    "cloud_init": cloudInit,
                    "poll_count": String(pollCount)
                ])
                if pollCount % 5 == 0 {
                    fputs("msl: provisioning status: \(cloudInit) (poll #\(pollCount))\n", stderr)
                }
                if cloudInit == "done" {
                    let elapsed = runtimeMonotonicMs() - startMs
                    logger.log("provision_completed", fields: ["elapsed_ms": String(elapsed)])
                    fputs("msl: provisioning complete (\(elapsed / 1000)s)\n", stderr)
                    Foundation.exit(0)
                }
                if cloudInit == "error" {
                    let detail = resp.meta?["cloud_init_detail"] ?? ""
                    fputs("msl: provisioning failed (cloud-init error)\(detail.isEmpty ? "" : ": \(detail)")\n", stderr)
                    Foundation.exit(1)
                }
            } else {
                let errMsg = resp.error ?? "unknown"
                fputs("msl: provision_status error: \(errMsg)\n", stderr)
            }
            // Sleep in small increments to check interrupt flag quickly
            for _ in 0..<20 {
                if isInterrupted() { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }

        let elapsed = runtimeMonotonicMs() - startMs
        logger.log("provision_timeout", fields: ["elapsed_ms": String(elapsed)])
        fputs("msl: provisioning timed out after \(timeoutSec)s\n", stderr)
        Foundation.exit(1)
    }

    /// Run `msl run <cmd>`: execute a command in the VM.
    public func runCommand(argv: [String], timeoutSec: Int = 0, instanceName: String? = nil) throws -> Never {
        let startMs = runtimeMonotonicMs()
        let target = try resolveRuntimeTarget(explicitInstanceName: instanceName)
        let workspacePolicy = evaluateWorkspaceStartupPolicy(instanceName: target.instanceName, metadataURL: target.metadataURL)
        guard !argv.isEmpty else {
            throw MSLRuntimeError("run requires at least one argument")
        }
        logger.log("run_command_started", fields: ["argv0": argv[0]])

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
        let execCwd = prepareWorkspaceIfNeeded(policy: workspacePolicy, instanceName: target.instanceName)

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
        let resp = try daemonClient.send(RuntimeControlRequest(
            op: "exec",
            argv: argv,
            timeoutMs: execTimeoutMs,
            sessionId: sessionID,
            cwd: execCwd
        ))

        if resp.ok {
            if let stdout = resp.stdout, !stdout.isEmpty {
                let line = stdout.hasSuffix("\n") ? stdout : stdout + "\n"
                FileHandle.standardOutput.write(Data(line.utf8))
            }
            if let stderr = resp.stderr, !stderr.isEmpty {
                let line = stderr.hasSuffix("\n") ? stderr : stderr + "\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
            let code = resp.exitCode ?? 0
            logger.log("run_command_completed", fields: [
                "argv0": argv[0],
                "exit_code": String(code),
                "elapsed_ms": String(runtimeMonotonicMs() - startMs)
            ])
            Foundation.exit(code)
        } else {
            let errMsg = resp.error ?? "exec failed"
            logger.log("run_command_error", fields: [
                "argv0": argv[0],
                "error": errMsg,
                "elapsed_ms": String(runtimeMonotonicMs() - startMs)
            ])
            fputs("msl: \(errMsg)\n", stderr)
            Foundation.exit(1)
        }
    }

    public func printStatus(instanceName: String? = nil, all: Bool = false) throws {
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
            activeSessionCount: state.activeSessionCount,
            idleTimer: state.idleTimer,
            runtimeUser: state.runtimeUser,
            initChannel: state.initChannel,
            runtimeHostPid: state.runtimeHostPid,
            runtimeControlSocket: state.runtimeControlSocket,
            lastError: nil,
            lastTransitionEpochMs: state.lastTransitionEpochMs
        )
        let instances = (state.instances?.isEmpty == false ? state.instances! : [fallbackInstance]).sorted {
            $0.instance < $1.instance
        }

        if all {
            print("INSTANCE\tSTATE\tSESSIONS\tIDLE\tPID\tLAST_ERROR")
            for entry in instances {
                let idle = entry.idleTimer.armed ? "armed" : "not-armed"
                let pid = entry.runtimeHostPid.map(String.init) ?? "-"
                let lastError = entry.lastError?.replacingOccurrences(of: "\n", with: " ") ?? "-"
                print("\(entry.instance)\t\(entry.vmState.rawValue)\t\(entry.activeSessionCount)\t\(idle)\t\(pid)\t\(lastError)")
            }
            return
        }

        let targetInstance = instanceName ?? state.distro
        guard let selected = instances.first(where: { $0.instance == targetInstance }) else {
            throw MSLRuntimeError("instance '\(targetInstance)' not found")
        }
        print("instance: \(selected.instance)")
        print("state: \(selected.vmState.rawValue)")
        print("activeSessions: \(selected.activeSessionCount)")
        print("idleTimer: \(selected.idleTimer.armed ? "armed" : "not-armed")")
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
        print("instance: \(target.instanceName)")
        print("mode: \(meta["dns_mode"] ?? "unknown")")
        print("status: \(meta["dns_status"] ?? "unknown")")
        print("action: \(meta["dns_action"] ?? "-")")
        print("source: \(meta["dns_source"] ?? "-")")
        print("nameservers: \(meta["nameserver_count"] ?? "0")")
        print("searchDomains: \(meta["search_domain_count"] ?? "0")")
        if let errorClass = meta["error_class"], !errorClass.isEmpty {
            print("errorClass: \(errorClass)")
        }
        if let error = meta["error"], !error.isEmpty {
            print("error: \(error)")
        }
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
        // Try sending stop via daemon control socket first
        var attemptedDaemonStop = false
        do {
            let state = try lock.withExclusiveLock(timeoutSec: 2) { try store.loadState() }
            let daemonPid = state.daemonHostPid ?? state.runtimeHostPid
            if let daemonPid, isDaemonAlive(pid: daemonPid) {
                attemptedDaemonStop = true
                let socketPath = state.daemonControlSocket ?? state.runtimeControlSocket ?? paths.runtimeControlSocketFile.path
                let client = RuntimeControlClient(socketPath: socketPath)
                let resp = try client.send(RuntimeControlRequest(
                    op: "instance_stop",
                    instance: instanceName,
                    all: all,
                    callerCwd: currentCallerCwd()
                ))
                if resp.ok {
                    if all || (instanceName == nil || instanceName == state.distro) {
                        for _ in 0..<30 {
                            if !isDaemonAlive(pid: daemonPid) { break }
                            Thread.sleep(forTimeInterval: 0.1)
                        }
                    }
                    if all {
                        print("stopped all")
                    } else if let instanceName, !instanceName.isEmpty {
                        print("stopped \(instanceName)")
                    } else {
                        print("stopped")
                    }
                    return
                }
                throw MSLRuntimeError(resp.error ?? "stop failed")
            }
        } catch {
            if attemptedDaemonStop {
                throw error
            }
            // Fall through to legacy stop
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

    public func addPortMapping(_ raw: String, instanceName: String? = nil) throws {
        let target = try resolveRuntimeTarget(explicitInstanceName: instanceName)
        let mapping = try parsePortMapping(raw, instanceName: target.instanceName)
        var runtimeSocket: String?
        var instanceRunning = false
        try lock.withExclusiveLock {
            try bootstrap.ensureBootstrapped(context: .runtime)
            let runtime = try store.loadState()
            instanceRunning = isInstanceRunning(runtime, instanceName: target.instanceName)
            runtimeSocket = runtime.runtimeControlSocket
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

        let runtimeStatus: [RuntimePortStatusItem] = (try? RuntimeControlClient(socketPath: paths.runtimeControlSocketFile.path)
            .send(RuntimeControlRequest(op: "port_ls", instance: target.instanceName, hostPort: nil, guestPort: nil)).items) ?? []

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
                    instance: $0.instance ?? target.instanceName
                )
            }
        }

        print("HOST\tGUEST\tBIND\tSOURCE\tSTATE\tDETAIL")
        for mapping in mappings {
            let item = runtimeStatus.first(where: { $0.hostPort == mapping.hostPort })
            let source = manualHostPorts.contains(mapping.hostPort) ? "manual" : "auto"
            let status = (item?.active == true) ? "active" : "inactive"
            let detail = item?.error?.replacingOccurrences(of: "\n", with: " ") ?? "-"
            print("\(mapping.hostPort)\t\(mapping.guestPort)\t\(mapping.bindAddress)\t\(source)\t\(status)\t\(detail)")
        }
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
            let runtime = try store.loadState()
            instanceRunning = isInstanceRunning(runtime, instanceName: target.instanceName)
            runtimeSocket = runtime.runtimeControlSocket
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
        if ioctl(FileHandle.standardInput.fileDescriptor, TIOCGWINSZ, &size) != 0 {
            return (nil, nil)
        }
        return (Int(size.ws_row), Int(size.ws_col))
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
                }
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
    /// During initial provisioning (no bootstrap log yet), cloud-init may still
    /// be writing to the filesystem. Killing the VM prematurely causes FS corruption.
    /// Use a long timeout (5 min) to allow cloud-init to complete safely.
    private func resolveIdleTimeoutMs() -> Int64 {
        if let raw = ProcessInfo.processInfo.environment["MSL_IDLE_TIMEOUT_MS"],
           let val = Int64(raw), val > 0 {
            return val
        }
        if !FileManager.default.fileExists(atPath: paths.mslHostInitBootstrapLogFile.path) {
            // First provisioning — cloud-init may still be running
            return 300_000  // 5 minutes
        }
        return 10_000  // 10 seconds (normal)
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
            return URL(fileURLWithPath: trimmed).resolvingSymlinksInPath().path
        }
        if trimmed.contains("/") {
            let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            return URL(fileURLWithPath: trimmed, relativeTo: cwd)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
        }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = String(dir) + "/" + trimmed
                if fileManager.isExecutableFile(atPath: candidate) {
                    return URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
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

    private func resolveRuntimeTarget(explicitInstanceName: String?) throws -> (instanceName: String, metadataURL: URL) {
        let configured = try defaultInstanceStore.loadDefaultInstanceName()
        let metadataURL = try distributionManager.runtimeMetadataURL(
            explicitInstanceName: explicitInstanceName,
            defaultInstanceName: configured
        )
        let instanceName = metadataURL.deletingLastPathComponent().lastPathComponent
        return (instanceName, metadataURL)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let gib = Double(bytes) / Double(1024 * 1024 * 1024)
        return String(format: "%.2f GiB", gib)
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
