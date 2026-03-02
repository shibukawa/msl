import Foundation
import Darwin

/// VMオーナーデーモンプロセス。VM の起動・保持、vsock 管理、
/// control socket でCLI からのリクエストを受け付ける。
public final class DaemonServer {
    private struct ConvergedRuntimeUserResult {
        var runtimeUser: RuntimeUserState
        var adminGroup: String
    }

    private let paths: MSLPaths
    private let lock: FileLock
    private let store: StateStore
    private let bootstrap: BootstrapManager
    private let sessions: SessionManager
    private let logger: MSLLogger
    private let executablePath: String
    private let explicitInstanceName: String?
    private let distributionManager: DistributionManager
    private let defaultInstanceStore: DefaultInstanceStore

    private var initClient: InitChannelClient?
    private var vmRunner: VirtualMachineRunner?
    private var controlServer: RuntimeControlServer?
    private var forwarder: PortForwardingManager?
    private var runtimeUser: RuntimeUserState?
    private var runtimeMetadataURL: URL?
    private let dnsStateLock = NSLock()
    private let dnsReconcileLock = NSLock()
    private var runtimeDNSMeta: [String: String] = [
        "dns_mode": "host",
        "dns_status": "unknown",
        "dns_action": "-",
        "dns_source": "-",
        "nameserver_count": "0",
        "search_domain_count": "0",
        "last_reconcile_epoch_ms": "0"
    ]
    private let dnsMonitorQueue = DispatchQueue(label: "msl.daemon.dns-monitor")
    private var dnsMonitorTimer: DispatchSourceTimer?
    private var lastHostResolverSnapshotHash: String?

    private let stopSemaphore = DispatchSemaphore(value: 0)
    private var idleTimerSource: DispatchSourceTimer?
    private let idleTimerQueue = DispatchQueue(label: "msl.daemon.idle")
    private let memoryReclaimQueue = DispatchQueue(label: "msl.daemon.memory-reclaim")
    private let reclaimStateQueue = DispatchQueue(label: "msl.daemon.memory-reclaim.state")
    private var memoryReclaimTimer: DispatchSourceTimer?
#if canImport(Darwin)
    private var hostMemoryPressureSource: DispatchSourceMemoryPressure?
#endif
    private var memoryReclaimPolicy: ResolvedMemoryReclaimPolicy = .defaultPolicy
    private var lastGuestActivityEpochMs: Int64 = nowEpochMs()
    private var lastShortIdleReclaimEpochMs: Int64?
    private var lastLongIdleReclaimEpochMs: Int64?
    private var lastHostPressureReclaimEpochMs: Int64?
    private var lastCacheCapReclaimEpochMs: Int64?
    private var cacheOverCapActive: Bool = false
    private let autoPortQueue = DispatchQueue(label: "msl.daemon.port-auto")
    private var autoPortTimer: DispatchSourceTimer?
    private let portMappingsSnapshotLock = NSLock()
    private var effectivePortMappingsSnapshot: EffectivePortMappings = .empty
    private var autoPortErrorsByHostPort: [Int: String] = [:]
    private var cacheShareEnvAdditions: [String: String] = [:]
    private static let legacyHostSharePrepareScript = """
    set -eu
    share_root="$1"
    workspace="$2"
    applied=0

    is_mount_target() {
      awk -v target="$1" '$5 == target { found=1 } END { exit(found ? 0 : 1) }' /proc/self/mountinfo
    }

    if ! is_mount_target "/mnt/macos"; then
      mkdir -p /mnt/macos
      mount -t virtiofs macos /mnt/macos
      applied=1
    fi

    if [ "$share_root" != "/" ]; then
      source_root="/mnt/macos$share_root"
      if [ ! -d "$source_root" ]; then
        echo "host share source is not accessible: $source_root" >&2
        exit 2
      fi
      mkdir -p "$share_root"
      if ! is_mount_target "$share_root"; then
        mount -o bind "$source_root" "$share_root"
        applied=1
      fi
    fi

    if [ "$share_root" = "/" ]; then
      source_workspace="/mnt/macos$workspace"
      if [ ! -e "$source_workspace" ]; then
        echo "workspace source is not accessible: $source_workspace" >&2
        exit 2
      fi
      mkdir -p "$workspace"
      if ! is_mount_target "$workspace"; then
        mount -o bind "$source_workspace" "$workspace"
        applied=1
      fi
    fi

    if [ "$applied" -eq 1 ]; then
      printf "applied"
    else
      printf "reused"
    fi
    """
    private static let cacheSharePrepareScript = """
    set -eu
    cache_root="$1"; shift
    runtime_home="$1"; shift
    host_home_guest="$1"; shift
    enable_apt="$1"; shift
    enable_apk="$1"; shift
    enable_go="$1"; shift
    enable_python="$1"; shift
    enable_npm="$1"; shift
    enable_pnpm="$1"; shift
    enable_yarn="$1"; shift
    enable_maven="$1"; shift
    enable_gradle="$1"; shift
    enable_composer="$1"; shift
    enable_scala="$1"; shift
    enable_ruby="$1"; shift
    enable_rust="$1"; shift
    enable_deno="$1"; shift
    enable_bun="$1"; shift
    enable_nuget="$1"; shift

    applied=0
    fallback=0

    is_mount_target() {
      awk -v target="$1" '$5 == target { found=1 } END { exit(found ? 0 : 1) }' /proc/self/mountinfo
    }

    ensure_dir() {
      path="$1"
      if mkdir -p "$path" 2>/dev/null; then
        return 0
      fi
      if command -v sudo >/dev/null 2>&1; then
        sudo -n mkdir -p "$path" 2>/dev/null && return 0
      fi
      return 1
    }

    bind_mount() {
      src="$1"
      dst="$2"
      if mount -o bind "$src" "$dst" 2>/dev/null; then
        return 0
      fi
      if command -v sudo >/dev/null 2>&1; then
        sudo -n mount -o bind "$src" "$dst" 2>/dev/null && return 0
      fi
      return 1
    }

    ensure_bind_mount() {
      src="$1"
      dst="$2"
      if [ ! -e "$src" ]; then
        fallback=$((fallback+1))
        return 0
      fi
      if ! ensure_dir "$dst"; then
        fallback=$((fallback+1))
        return 0
      fi
      if is_mount_target "$dst"; then
        return 0
      fi
      if bind_mount "$src" "$dst"; then
        applied=1
      else
        fallback=$((fallback+1))
      fi
      return 0
    }

    if [ -z "$runtime_home" ] || [ "${runtime_home#/}" = "$runtime_home" ]; then
      runtime_home="/root"
    fi

    if [ -z "$host_home_guest" ] || [ "${host_home_guest#/}" = "$host_home_guest" ]; then
      host_home_guest="/__msl_host_home_unavailable__"
    fi

    prefer_existing_dir() {
      fallback_path="$1"; shift
      for candidate_path in "$@"; do
        if [ -n "$candidate_path" ] && [ -d "$candidate_path" ]; then
          printf "%s" "$candidate_path"
          return 0
        fi
      done
      printf "%s" "$fallback_path"
    }

    mkdir -p "$cache_root" 2>/dev/null || true

    os_id=""
    version_id=""
    if [ -r /etc/os-release ]; then
      os_id="$(. /etc/os-release; printf '%s' "${ID:-}")"
      version_id="$(. /etc/os-release; printf '%s' "${VERSION_ID:-}")"
    fi

    if [ "$enable_apt" = "1" ] && command -v apt-get >/dev/null 2>&1; then
      release_key="ubuntu-${version_id:-unknown}"
      archives_src="$cache_root/apt/$release_key/archives"
      lists_src="$cache_root/apt/$release_key/lists"
      mkdir -p "$archives_src/partial" "$lists_src/partial" 2>/dev/null || true
      ensure_bind_mount "$archives_src" "/var/cache/apt/archives"
      ensure_bind_mount "$lists_src" "/var/lib/apt/lists"
    fi

    if [ "$enable_apk" = "1" ] && command -v apk >/dev/null 2>&1; then
      apk_src="$cache_root/apk/cache"
      mkdir -p "$apk_src" 2>/dev/null || true
      ensure_bind_mount "$apk_src" "/var/cache/apk"
    fi

    if [ "$enable_go" = "1" ]; then
      mkdir -p "$cache_root/go/modcache" "$cache_root/go/sumdb" 2>/dev/null || true
      go_mod_src="$(prefer_existing_dir "$cache_root/go/modcache" "$host_home_guest/go/pkg/mod")"
      go_sumdb_src="$(prefer_existing_dir "$cache_root/go/sumdb" "$host_home_guest/go/pkg/sumdb")"
      ensure_bind_mount "$go_mod_src" "$runtime_home/go/pkg/mod"
      ensure_bind_mount "$go_sumdb_src" "$runtime_home/go/pkg/sumdb"
    fi
    if [ "$enable_python" = "1" ]; then
      mkdir -p "$cache_root/python/pip" 2>/dev/null || true
      python_pip_src="$(prefer_existing_dir "$cache_root/python/pip" "$host_home_guest/Library/Caches/pip" "$host_home_guest/.cache/pip")"
      ensure_bind_mount "$python_pip_src" "$runtime_home/.cache/pip"
    fi
    if [ "$enable_npm" = "1" ]; then
      mkdir -p "$cache_root/node/npm" 2>/dev/null || true
      npm_src="$(prefer_existing_dir "$cache_root/node/npm" "$host_home_guest/.npm")"
      ensure_bind_mount "$npm_src" "$runtime_home/.npm"
    fi
    if [ "$enable_pnpm" = "1" ]; then
      mkdir -p "$cache_root/node/pnpm-store" 2>/dev/null || true
      pnpm_src="$(prefer_existing_dir "$cache_root/node/pnpm-store" "$host_home_guest/Library/pnpm/store" "$host_home_guest/.local/share/pnpm/store")"
      ensure_bind_mount "$pnpm_src" "$runtime_home/.local/share/pnpm/store"
    fi
    if [ "$enable_yarn" = "1" ]; then
      mkdir -p "$cache_root/node/yarn" 2>/dev/null || true
      yarn_src="$(prefer_existing_dir "$cache_root/node/yarn" "$host_home_guest/Library/Caches/Yarn" "$host_home_guest/.cache/yarn")"
      ensure_bind_mount "$yarn_src" "$runtime_home/.cache/yarn"
    fi
    if [ "$enable_maven" = "1" ]; then
      mkdir -p "$cache_root/java/maven-repo" 2>/dev/null || true
      maven_src="$(prefer_existing_dir "$cache_root/java/maven-repo" "$host_home_guest/.m2/repository")"
      ensure_bind_mount "$maven_src" "$runtime_home/.m2/repository"
    fi
    if [ "$enable_gradle" = "1" ]; then
      mkdir -p "$cache_root/java/gradle" 2>/dev/null || true
      gradle_src="$(prefer_existing_dir "$cache_root/java/gradle" "$host_home_guest/.gradle/caches")"
      ensure_bind_mount "$gradle_src" "$runtime_home/.gradle/caches"
    fi
    if [ "$enable_composer" = "1" ]; then
      mkdir -p "$cache_root/php/composer" 2>/dev/null || true
      composer_src="$(prefer_existing_dir "$cache_root/php/composer" "$host_home_guest/Library/Caches/composer" "$host_home_guest/.cache/composer")"
      ensure_bind_mount "$composer_src" "$runtime_home/.cache/composer"
    fi
    if [ "$enable_scala" = "1" ]; then
      mkdir -p "$cache_root/scala/coursier" "$cache_root/scala/ivy2" 2>/dev/null || true
      scala_coursier_src="$(prefer_existing_dir "$cache_root/scala/coursier" "$host_home_guest/Library/Caches/Coursier/v1" "$host_home_guest/.cache/coursier")"
      scala_ivy_src="$(prefer_existing_dir "$cache_root/scala/ivy2" "$host_home_guest/.ivy2/cache")"
      ensure_bind_mount "$scala_coursier_src" "$runtime_home/.cache/coursier"
      ensure_bind_mount "$scala_ivy_src" "$runtime_home/.ivy2/cache"
    fi
    if [ "$enable_ruby" = "1" ]; then
      mkdir -p "$cache_root/ruby/bundle" 2>/dev/null || true
      ruby_bundle_src="$(prefer_existing_dir "$cache_root/ruby/bundle" "$host_home_guest/.bundle/cache")"
      ensure_bind_mount "$ruby_bundle_src" "$runtime_home/.bundle/cache"
    fi
    if [ "$enable_rust" = "1" ]; then
      mkdir -p "$cache_root/rust/cargo-home/registry" "$cache_root/rust/cargo-home/git" 2>/dev/null || true
      rust_registry_src="$(prefer_existing_dir "$cache_root/rust/cargo-home/registry" "$host_home_guest/.cargo/registry")"
      rust_git_src="$(prefer_existing_dir "$cache_root/rust/cargo-home/git" "$host_home_guest/.cargo/git")"
      ensure_bind_mount "$rust_registry_src" "$runtime_home/.cargo/registry"
      ensure_bind_mount "$rust_git_src" "$runtime_home/.cargo/git"
    fi
    if [ "$enable_deno" = "1" ]; then
      mkdir -p "$cache_root/deno/dir" 2>/dev/null || true
      deno_src="$(prefer_existing_dir "$cache_root/deno/dir" "$host_home_guest/Library/Caches/deno" "$host_home_guest/.cache/deno")"
      ensure_bind_mount "$deno_src" "$runtime_home/.cache/deno"
    fi
    if [ "$enable_bun" = "1" ]; then
      mkdir -p "$cache_root/bun/cache" 2>/dev/null || true
      bun_src="$(prefer_existing_dir "$cache_root/bun/cache" "$host_home_guest/.bun/install/cache")"
      ensure_bind_mount "$bun_src" "$runtime_home/.bun/install/cache"
    fi
    if [ "$enable_nuget" = "1" ]; then
      mkdir -p "$cache_root/dotnet/nuget-packages" "$cache_root/dotnet/nuget-http" 2>/dev/null || true
      nuget_packages_src="$(prefer_existing_dir "$cache_root/dotnet/nuget-packages" "$host_home_guest/.nuget/packages")"
      nuget_http_src="$(prefer_existing_dir "$cache_root/dotnet/nuget-http" "$host_home_guest/Library/Caches/NuGet/v3-cache" "$host_home_guest/.local/share/NuGet/v3-cache")"
      ensure_bind_mount "$nuget_packages_src" "$runtime_home/.nuget/packages"
      ensure_bind_mount "$nuget_http_src" "$runtime_home/.local/share/NuGet/v3-cache"
    fi

    status="reused"
    if [ "$fallback" -gt 0 ]; then
      status="partial"
    elif [ "$applied" -eq 1 ]; then
      status="applied"
    fi
    printf "%s" "$status"
    """

    public init(
        executablePath: String,
        explicitInstanceName: String? = nil,
        fileManager: FileManager = .default
    ) throws {
        if let homeOverride = ProcessInfo.processInfo.environment["MSL_HOME"], !homeOverride.isEmpty {
            self.paths = MSLPaths(homeDirectoryURL: URL(fileURLWithPath: homeOverride))
        } else {
            self.paths = MSLPaths(fileManager: fileManager)
        }

        try fileManager.createDirectory(at: paths.runtime, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.appLogs, withIntermediateDirectories: true)

        self.logger = MSLLogger(logFile: paths.logs.appendingPathComponent("msl.log", isDirectory: false), fileManager: fileManager)
        self.lock = try FileLock(path: paths.lockFile.path)
        self.store = StateStore(paths: paths, fileManager: fileManager)
        self.bootstrap = BootstrapManager(paths: paths, logger: logger, fileManager: fileManager)
        self.distributionManager = DistributionManager(paths: paths, logger: logger, fileManager: fileManager)
        self.defaultInstanceStore = DefaultInstanceStore(paths: paths, fileManager: fileManager)
        self.sessions = SessionManager(store: store)
        self.executablePath = executablePath
        self.explicitInstanceName = explicitInstanceName?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Main daemon entry point. Blocks until idle timeout or explicit stop.
    public func run() throws -> Never {
        logger.log("daemon_started", fields: ["pid": String(getpid())])
        let startupStartMs = daemonMonotonicMs()

        // 1. Bootstrap
        let bootstrapStartMs = daemonMonotonicMs()
        try lock.withExclusiveLock {
            try bootstrap.ensureBootstrapped(context: .runtime)
        }
        logger.log("startup_phase_duration_ms", fields: [
            "phase": "bootstrap_total",
            "elapsed_ms": String(max(0, daemonMonotonicMs() - bootstrapStartMs))
        ])

        let metadataResolveStartMs = daemonMonotonicMs()
        let metadataURL = try resolveRuntimeMetadataURL(explicitInstanceName: explicitInstanceName)
        let instanceName = metadataURL.deletingLastPathComponent().lastPathComponent
        let initialMetadata = try distributionManager.readOrRebuildInstanceMetadata(at: metadataURL)
        self.runtimeMetadataURL = metadataURL
        logger.log("startup_phase_duration_ms", fields: [
            "phase": "runtime_metadata_resolve",
            "elapsed_ms": String(max(0, daemonMonotonicMs() - metadataResolveStartMs)),
            "instance": instanceName
        ])
        logger.log("runtime_target_resolved", fields: [
            "instance": instanceName,
            "metadata": metadataURL.path
        ])
        let bootProfile = try resolveBootProfile(metadataURL: metadataURL, instanceName: instanceName)

        // 2. Start VM and get init channel client
        let runner = VirtualMachineRunner(
            paths: paths,
            metadataURL: metadataURL,
            bootProfile: bootProfile,
            logger: logger,
            initProbeHandler: { [weak self] probe in
                self?.updateInitChannelState(probe)
            }
        )
        self.vmRunner = runner

        let client: InitChannelClient
        do {
            client = try runner.startVMForDaemon()
        } catch {
            logger.log("daemon_vm_start_failed", fields: ["error": String(describing: error)])
            updateStateStopped()
            Foundation.exit(1)
        }
        self.initClient = client

        prepareHostShareRootMountOnStartup(client: client)
        syncGuestClockAtStartup(client: client, instanceName: instanceName)
        logger.log("startup_total_duration_ms", fields: [
            "elapsed_ms": String(max(0, daemonMonotonicMs() - startupStartMs)),
            "instance": instanceName
        ])

        // 3. Converge runtime user (Step9)
        do {
            let firstBootPending = initialMetadata.bootstrap?.firstBootPending ?? true
            logger.log("su_bootstrap_started", fields: [
                "instance": instanceName,
                "first_boot": firstBootPending ? "true" : "false",
                "bootstrap_version": String(initialMetadata.bootstrap?.privilegeBootstrapVersion ?? 1)
            ])

            let resolved = try convergeRuntimeUser(
                client: client,
                metadataURL: metadataURL,
                instanceName: instanceName
            )
            self.runtimeUser = resolved.runtimeUser
            try distributionManager.writeBootstrapResult(
                metadataURL: metadataURL,
                result: "success",
                runtimeUser: resolved.runtimeUser,
                fallbackAdminGroup: resolved.adminGroup
            )
            logger.log("su_bootstrap_validation_passed", fields: [
                "instance": instanceName,
                "user": resolved.runtimeUser.name,
                "uid": String(resolved.runtimeUser.uid),
                "gid": String(resolved.runtimeUser.gid)
            ])
        } catch {
            logger.log("user_convergence_failed", fields: [
                "instance": instanceName,
                "metadata": metadataURL.path,
                "error": String(describing: error)
            ])
            try? distributionManager.writeBootstrapResult(
                metadataURL: metadataURL,
                result: "failed",
                runtimeUser: nil,
                fallbackAdminGroup: nil
            )
            logger.log("su_bootstrap_failed", fields: [
                "instance": instanceName,
                "error": String(describing: error)
            ])
            runner.stopRunningVM()
            updateStateStopped()
            Foundation.exit(1)
        }
        configureMemoryReclaimPolicy()
        ensureGuestMSLCommandAlias(client: client)
        let dnsStartup = handleDNSReconcile(RuntimeControlRequest(op: "dns_reconcile", dnsSource: "startup"))
        if !dnsStartup.ok {
            logger.log("dns_reconcile_failed", fields: [
                "dns_source": "startup",
                "error": dnsStartup.error ?? "unknown"
            ])
        }
        startDNSMonitorLoop()

        // 4. Set up port forwarding
        let guestIPHint = ProcessInfo.processInfo.environment["MSL_GUEST_IP"]
        let guestIPResolver = GuestIPResolver(explicitIP: guestIPHint)
        let portForwarder = PortForwardingManager(logger: logger, guestIPResolver: guestIPResolver)
        self.forwarder = portForwarder

        syncEffectivePortMappings(autoHostPorts: [], reason: "startup")

        // 5. Start control socket server
        let controlSocketPath = paths.runtimeControlSocketFile.path
        let server = RuntimeControlServer(socketPath: controlSocketPath) { [weak self] request in
            self?.handleControlRequest(request) ?? RuntimeControlResponse(ok: false, error: "daemon unavailable")
        }
        self.controlServer = server

        do {
            try server.start()
            logger.log("daemon_control_socket_started", fields: ["path": controlSocketPath])
        } catch {
            logger.log("daemon_control_socket_failed", fields: ["error": String(describing: error)])
            runner.stopRunningVM()
            Foundation.exit(1)
        }

        // 6. Update state
        try lock.withExclusiveLock {
            var state = try store.loadState()
            state.vmState = .running
            state.distro = instanceName
            state.lastTransitionEpochMs = nowEpochMs()
            state.runtimeHostPid = Int32(getpid())
            state.runtimeControlSocket = controlSocketPath
            state.activeSessionCount = 0
            state.idleTimer = IdleTimerState(armed: false, deadlineEpochMs: nil)
            state.runtimeUser = runtimeUser
            try store.saveState(state)
        }

        // 7. Arm initial idle timer (VM has no sessions yet)
        startAutoPortForwardLoop()
        armIdleTimer()
        startMemoryReclaimLoop()

        logger.log("daemon_ready")

        // 8. Wait for stop signal
        stopSemaphore.wait()

        // 9. Cleanup
        shutdown()
        Foundation.exit(0)
    }

    private func resolveRuntimeMetadataURL(explicitInstanceName: String?) throws -> URL {
        let configured = try defaultInstanceStore.loadDefaultInstanceName()
        return try distributionManager.runtimeMetadataURL(
            explicitInstanceName: explicitInstanceName,
            defaultInstanceName: configured
        )
    }

    private func syncGuestClockAtStartup(client: InitChannelClient, instanceName: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let utc = formatter.string(from: Date())
        let script = "date -u -s '\(utc)' >/dev/null 2>&1 || busybox date -u -s '\(utc)' >/dev/null 2>&1"
        do {
            let response = try client.send(InitChannelRequest(
                op: "exec",
                argv: ["/bin/sh", "-lc", script],
                timeoutMs: 3_000
            ))
            if response.ok, (response.exitCode ?? 1) == 0 {
                logger.log("clock_sync_startup_succeeded", fields: [
                    "instance": instanceName,
                    "utc": utc
                ])
            } else {
                logger.log("clock_sync_startup_failed", fields: [
                    "instance": instanceName,
                    "utc": utc,
                    "error": response.error?.message ?? response.stderr ?? "failed"
                ])
            }
        } catch {
            logger.log("clock_sync_startup_failed", fields: [
                "instance": instanceName,
                "utc": utc,
                "error": String(describing: error)
            ])
        }
    }

    private func resolveBootProfile(metadataURL: URL, instanceName: String) throws -> RuntimeBootProfile {
        let configKernel = try defaultInstanceStore.loadDefaultKernelProfileRef()
        let resolver = RuntimeBootProfileResolver(
            paths: paths,
            logger: logger,
            environment: ProcessInfo.processInfo.environment
        )
        return try resolver.resolve(
            metadataURL: metadataURL,
            instanceName: instanceName,
            defaultKernelProfileRef: configKernel
        )
    }

    // MARK: - Control Socket Request Handler

    private func handleControlRequest(_ request: RuntimeControlRequest) -> RuntimeControlResponse {
        switch request.op {
        // --- exec ---
        case "exec":
            return handleExec(request)
        case "workspace_prepare":
            return handleWorkspacePrepare(request)
        case "cache_share_prepare":
            return handleCacheSharePrepare()

        // --- provision_status ---
        case "provision_status":
            return handleProvisionStatus()

        // --- PTY ops ---
        case "pty_open":
            return handlePtyOpen(request)
        case "pty_read":
            return handlePtyRead(request)
        case "pty_write":
            return handlePtyWrite(request)
        case "pty_resize":
            return handlePtyResize(request)
        case "pty_close":
            return handlePtyClose(request)

        // --- session management ---
        case "session_register":
            return handleSessionRegister()
        case "session_unregister":
            return handleSessionUnregister(request)

        // --- port forwarding (existing) ---
        case "port_add":
            return handlePortAdd(request)
        case "port_rm":
            return handlePortRemove(request)
        case "port_ls":
            return handlePortList()
        case "memory_status":
            return handleMemoryStatus()
        case "dns_reconcile":
            return handleDNSReconcile(request)
        case "dns_status":
            return handleDNSStatus()

        // --- stop ---
        case "stop":
            return handleStop()

        default:
            return RuntimeControlResponse(ok: false, error: "unsupported op: \(request.op)")
        }
    }

    // MARK: - exec

    private func handleExec(_ request: RuntimeControlRequest) -> RuntimeControlResponse {
        guard let client = initClient else {
            return RuntimeControlResponse(ok: false, error: "init channel not available")
        }
        maybeReconcileDNSBeforeGuestOperation()
        guard let argv = request.argv, !argv.isEmpty else {
            return RuntimeControlResponse(ok: false, error: "missing argv")
        }
        let execTarget = resolveCWDForwarding(argv: argv, cwd: request.cwd)

        noteGuestActivity()
        // 0 means no timeout for guest exec.
        let timeoutMs = request.timeoutMs ?? 0
        logger.log("run_command_started", fields: ["argv0": argv[0]])

        do {
            let initReq = InitChannelRequest(
                op: "exec",
                argv: execTarget.argv,
                envAdditions: cacheShareEnvAdditions.isEmpty ? nil : cacheShareEnvAdditions,
                cwd: execTarget.cwd,
                timeoutMs: timeoutMs
            )
            let initResp = try client.send(initReq)

            if initResp.ok {
                logger.log("run_command_completed", fields: [
                    "argv0": argv[0],
                    "exit_code": String(initResp.exitCode ?? 0)
                ])
                return RuntimeControlResponse(
                    ok: true,
                    stdout: initResp.stdout,
                    stderr: initResp.stderr,
                    exitCode: initResp.exitCode
                )
            } else {
                let errMsg = initResp.error?.message ?? "exec failed"
                return RuntimeControlResponse(ok: false, error: errMsg)
            }
        } catch {
            logger.log("run_command_error", fields: [
                "argv0": argv[0],
                "error": String(describing: error)
            ])
            return RuntimeControlResponse(ok: false, error: String(describing: error))
        }
    }

    // MARK: - provision_status

    private func handleProvisionStatus() -> RuntimeControlResponse {
        guard let client = initClient else {
            return RuntimeControlResponse(ok: false, error: "init channel not available")
        }

        do {
            let resp = try client.convergeStatus()
            let cloudInit = resp.meta?["cloud_init"] ?? resp.meta?["convergence"] ?? "unknown"
            return RuntimeControlResponse(
                ok: true,
                meta: ["cloud_init": cloudInit]
            )
        } catch {
            return RuntimeControlResponse(ok: false, error: String(describing: error))
        }
    }

    private func handleWorkspacePrepare(_ request: RuntimeControlRequest) -> RuntimeControlResponse {
        guard let client = initClient else {
            return RuntimeControlResponse(ok: false, error: "init channel not available")
        }
        guard let workspacePath = request.cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
              !workspacePath.isEmpty,
              workspacePath.hasPrefix("/") else {
            return RuntimeControlResponse(ok: false, error: "missing or invalid cwd")
        }
        let hostShareRoot: String
        if let rawRoot = request.hostShareRoot?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawRoot.isEmpty {
            hostShareRoot = rawRoot
        } else {
            hostShareRoot = "/"
        }
        guard hostShareRoot.hasPrefix("/") else {
            return RuntimeControlResponse(ok: false, error: "invalid hostShareRoot")
        }

        do {
            let response = try client.send(InitChannelRequest(
                op: "host_share_prepare",
                cwd: workspacePath,
                hostShareRoot: hostShareRoot,
                timeoutMs: 4_000
            ))
            if response.error?.code == .unsupportedOp {
                logger.log("mount_entry_fallback_legacy", fields: [
                    "source_type": "workspace",
                    "host_real_path": hostShareRoot,
                    "guest_target": workspacePath
                ])
                if isWorkspaceVisibleInGuest(client: client, workspacePath: workspacePath) {
                    logger.log("mount_entry_reused", fields: [
                        "source_type": "workspace",
                        "host_real_path": hostShareRoot,
                        "guest_target": workspacePath,
                        "mode": "rw",
                        "required": "false"
                    ])
                    return RuntimeControlResponse(ok: true, meta: ["status": "reused"])
                }
                return handleLegacyWorkspacePrepare(
                    client: client,
                    workspacePath: workspacePath,
                    hostShareRoot: hostShareRoot
                )
            }

            let exitCode = response.exitCode ?? 0
            if response.ok, exitCode == 0 {
                let status = response.stdout?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() == "reused" || response.meta?["status"] == "reused" ? "reused" : "applied"
                logger.log(status == "reused" ? "mount_entry_reused" : "mount_entry_applied", fields: [
                    "source_type": "workspace",
                    "host_real_path": hostShareRoot,
                    "guest_target": workspacePath,
                    "mode": "rw",
                    "required": "false"
                ])
                return RuntimeControlResponse(ok: true, meta: ["status": status])
            }

            let errorMessage = response.error?.message ?? response.stderr ?? "workspace_prepare failed"
            logger.log("mount_entry_failed", fields: [
                "source_type": "workspace",
                "host_real_path": hostShareRoot,
                "guest_target": workspacePath,
                "mode": "rw",
                "required": "false",
                "error": errorMessage,
                "exit_code": String(exitCode)
            ])
            return RuntimeControlResponse(ok: false, error: errorMessage)
        } catch {
            logger.log("mount_entry_failed", fields: [
                "source_type": "workspace",
                "host_real_path": hostShareRoot,
                "guest_target": workspacePath,
                "mode": "rw",
                "required": "false",
                "error": String(describing: error)
            ])
            return RuntimeControlResponse(ok: false, error: String(describing: error))
        }
    }

    private func handleCacheSharePrepare() -> RuntimeControlResponse {
        guard let client = initClient else {
            return RuntimeControlResponse(ok: false, error: "init channel not available")
        }

        let policyConfig: CacheSharingConfig?
        let policySource: String
        if let metadataURL = runtimeMetadataURL,
           let metadata = try? distributionManager.readOrRebuildInstanceMetadata(at: metadataURL) {
            policyConfig = metadata.cacheSharing ?? CacheSharingPolicyResolver.defaultConfigForDistroFamily(
                metadata.distroFamily
                    ?? metadata.source.distro
                    ?? DistributionManager.inferDistroFamilyStatic(from: metadata.source.manifestId)
            )
            policySource = metadata.cacheSharing == nil ? "metadata_inferred" : "metadata"
        } else {
            policyConfig = nil
            policySource = "unavailable"
        }

        let policy = CacheSharingPolicyResolver.resolve(config: policyConfig)
        guard policy.enabled else {
            logger.log("cache_share_skipped", fields: [
                "reason": "disabled",
                "policy_source": policySource
            ])
            cacheShareEnvAdditions = [:]
            return RuntimeControlResponse(ok: true, meta: ["status": "skipped", "reason": "disabled"])
        }

        let hostShareRoot = resolveConfiguredHostShareRoot()
        let hostHome = ProcessInfo.processInfo.environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        let hostCacheRoot = CacheSharingPolicyResolver.hostCacheRootPath(hostHome: hostHome)
        let guestHostHome = CacheSharingPolicyResolver.guestPathForHostPath(hostPath: hostHome, hostShareRoot: hostShareRoot) ?? ""
        guard let guestCacheRoot = CacheSharingPolicyResolver.guestPathForHostPath(hostPath: hostCacheRoot, hostShareRoot: hostShareRoot) else {
            logger.log("cache_share_fallback_local", fields: [
                "reason": "host_cache_outside_share_root",
                "host_cache_root": hostCacheRoot,
                "host_share_root": hostShareRoot
            ])
            cacheShareEnvAdditions = [:]
            return RuntimeControlResponse(ok: true, meta: [
                "status": "skipped",
                "reason": "host_cache_outside_share_root",
            ])
        }

        let flags = CacheSharingPolicyResolver.toolFlagList(policy: policy)
        let runtimeHome = runtimeUser?.home ?? "/root"
        let enabledToolCount = flags.values.filter { $0 }.count
        let argv = [
            "/bin/sh",
            "-lc",
            Self.cacheSharePrepareScript,
            "msl-cache-share-prepare",
            guestCacheRoot,
            runtimeHome,
            guestHostHome,
            flags["apt"] == true ? "1" : "0",
            flags["apk"] == true ? "1" : "0",
            flags["go"] == true ? "1" : "0",
            flags["python"] == true ? "1" : "0",
            flags["npm"] == true ? "1" : "0",
            flags["pnpm"] == true ? "1" : "0",
            flags["yarn"] == true ? "1" : "0",
            flags["maven"] == true ? "1" : "0",
            flags["gradle"] == true ? "1" : "0",
            flags["composer"] == true ? "1" : "0",
            flags["scala"] == true ? "1" : "0",
            flags["ruby"] == true ? "1" : "0",
            flags["rust"] == true ? "1" : "0",
            flags["deno"] == true ? "1" : "0",
            flags["bun"] == true ? "1" : "0",
            flags["nuget"] == true ? "1" : "0",
        ]

        do {
            let response = try client.send(InitChannelRequest(
                op: "exec",
                argv: argv,
                runAsRoot: true,
                timeoutMs: 4_000
            ))
            let exitCode = response.exitCode ?? 0
            if response.ok, exitCode == 0 {
                cacheShareEnvAdditions = CacheSharingPolicyResolver.environment(
                    guestCacheRoot: guestCacheRoot,
                    policy: policy
                )
                let status = response.stdout?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let resolvedStatus: String
                if status == "applied" || status == "reused" || status == "partial" {
                    resolvedStatus = status ?? "applied"
                } else {
                    resolvedStatus = "applied"
                }
                logger.log("cache_share_applied", fields: [
                    "status": resolvedStatus,
                    "policy_source": policySource,
                    "guest_cache_root": guestCacheRoot,
                    "host_cache_root": hostCacheRoot,
                    "enabled_tools": String(enabledToolCount),
                    "runtime_home": runtimeHome
                ])
                return RuntimeControlResponse(ok: true, meta: [
                    "status": resolvedStatus,
                    "guest_cache_root": guestCacheRoot,
                    "host_cache_root": hostCacheRoot,
                    "enabled_tools": String(enabledToolCount),
                    "runtime_home": runtimeHome,
                ])
            }

            let errorMessage = response.error?.message ?? response.stderr ?? "cache_share_prepare failed"
            logger.log("cache_share_fallback_local", fields: [
                "reason": "guest_apply_failed",
                "policy_source": policySource,
                "error": errorMessage,
                "exit_code": String(exitCode)
            ])
            cacheShareEnvAdditions = [:]
            return RuntimeControlResponse(ok: true, meta: [
                "status": "partial",
                "reason": "guest_apply_failed",
            ])
        } catch {
            logger.log("cache_share_fallback_local", fields: [
                "reason": "request_error",
                "policy_source": policySource,
                "error": String(describing: error)
            ])
            cacheShareEnvAdditions = [:]
            return RuntimeControlResponse(ok: true, meta: [
                "status": "partial",
                "reason": "request_error",
            ])
        }
    }

    // MARK: - PTY ops

    private func handlePtyOpen(_ request: RuntimeControlRequest) -> RuntimeControlResponse {
        guard let client = initClient else {
            return RuntimeControlResponse(ok: false, error: "init channel not available")
        }
        maybeReconcileDNSBeforeGuestOperation()
        let defaultShell = runtimeUser?.shell ?? "/bin/sh"
        let argv = request.argv ?? [defaultShell, "-l"]
        let ptyTarget = resolveCWDForwarding(argv: argv, cwd: request.cwd)
        do {
            let resp = try client.ptyOpen(
                argv: ptyTarget.argv,
                cwd: ptyTarget.cwd,
                envAdditions: cacheShareEnvAdditions.isEmpty ? nil : cacheShareEnvAdditions,
                rows: request.rows,
                cols: request.cols,
                timeoutMs: 3_000
            )
            if resp.ok, let ptyId = resp.ptyId {
                return RuntimeControlResponse(ok: true, ptyId: ptyId)
            }
            return RuntimeControlResponse(ok: false, error: resp.error?.message ?? "pty_open failed")
        } catch {
            return RuntimeControlResponse(ok: false, error: String(describing: error))
        }
    }

    private func handlePtyRead(_ request: RuntimeControlRequest) -> RuntimeControlResponse {
        guard let client = initClient else {
            return RuntimeControlResponse(ok: false, error: "init channel not available")
        }
        guard let ptyId = request.ptyId else {
            return RuntimeControlResponse(ok: false, error: "missing ptyId")
        }
        do {
            let resp = try client.ptyRead(ptyId: ptyId, timeoutMs: request.timeoutMs ?? 1_000)
            return RuntimeControlResponse(
                ok: resp.ok,
                error: resp.error?.message,
                exitCode: resp.exitCode,
                dataBase64: resp.dataBase64,
                meta: resp.meta
            )
        } catch {
            return RuntimeControlResponse(ok: false, error: String(describing: error))
        }
    }

    private func resolveCWDForwarding(argv: [String], cwd: String?) -> (argv: [String], cwd: String?) {
        guard let cwdRaw = cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cwdRaw.isEmpty,
              cwdRaw.hasPrefix("/") else {
            return (argv, cwd)
        }
        return (
            [
                "/bin/sh",
                "-lc",
                "cd \"$1\" && shift && exec \"$@\"",
                "msl-cwd",
                cwdRaw
            ] + argv,
            nil
        )
    }

    private func handleLegacyWorkspacePrepare(
        client: InitChannelClient,
        workspacePath: String,
        hostShareRoot: String
    ) -> RuntimeControlResponse {
        do {
            let response = try client.send(InitChannelRequest(
                op: "exec",
                argv: [
                    "/bin/sh",
                    "-lc",
                    Self.legacyHostSharePrepareScript,
                    "msl-workspace-prepare",
                    hostShareRoot,
                    workspacePath
                ],
                runAsRoot: true,
                timeoutMs: 4_000
            ))

            let exitCode = response.exitCode ?? 0
            if response.ok, exitCode == 0 {
                let status = response.stdout?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() == "reused" ? "reused" : "applied"
                logger.log(status == "reused" ? "mount_entry_reused" : "mount_entry_applied", fields: [
                    "source_type": "workspace",
                    "host_real_path": hostShareRoot,
                    "guest_target": workspacePath,
                    "mode": "rw",
                    "required": "false"
                ])
                return RuntimeControlResponse(ok: true, meta: ["status": status])
            }

            let errorMessage = response.error?.message ?? response.stderr ?? "workspace_prepare failed"
            logger.log("mount_entry_failed", fields: [
                "source_type": "workspace",
                "host_real_path": hostShareRoot,
                "guest_target": workspacePath,
                "mode": "rw",
                "required": "false",
                "error": errorMessage,
                "exit_code": String(exitCode)
            ])
            return RuntimeControlResponse(ok: false, error: errorMessage)
        } catch {
            logger.log("mount_entry_failed", fields: [
                "source_type": "workspace",
                "host_real_path": hostShareRoot,
                "guest_target": workspacePath,
                "mode": "rw",
                "required": "false",
                "error": String(describing: error)
            ])
            return RuntimeControlResponse(ok: false, error: String(describing: error))
        }
    }

    private func isWorkspaceVisibleInGuest(client: InitChannelClient, workspacePath: String) -> Bool {
        do {
            let response = try client.send(InitChannelRequest(
                op: "exec",
                argv: [
                    "/bin/sh",
                    "-lc",
                    "[ -d \"$1\" ]",
                    "msl-workspace-visible",
                    workspacePath
                ],
                timeoutMs: 1_000
            ))
            return response.ok && (response.exitCode ?? 1) == 0
        } catch {
            return false
        }
    }

    private func prepareHostShareRootMountOnStartup(client: InitChannelClient) {
        let hostShareRoot = resolveConfiguredHostShareRoot()
        do {
            let response = try client.send(InitChannelRequest(
                op: "host_share_prepare",
                hostShareRoot: hostShareRoot,
                timeoutMs: 4_000
            ))
            if response.error?.code == .unsupportedOp {
                logger.log("mount_entry_fallback_legacy", fields: [
                    "source_type": "workspace",
                    "host_real_path": hostShareRoot,
                    "guest_target": "/"
                ])
                let fallback = handleLegacyWorkspacePrepare(
                    client: client,
                    workspacePath: "/",
                    hostShareRoot: hostShareRoot
                )
                if fallback.ok {
                    logger.log("host_share_root_prepared", fields: [
                        "host_real_path": hostShareRoot,
                        "status": fallback.meta?["status"] ?? "applied",
                        "mode": "startup"
                    ])
                } else {
                    logger.log("host_share_root_prepare_failed", fields: [
                        "host_real_path": hostShareRoot,
                        "error": fallback.error ?? "legacy_prepare_failed"
                    ])
                }
                return
            }

            let exitCode = response.exitCode ?? 0
            if response.ok, exitCode == 0 {
                let status = response.stdout?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() == "reused" || response.meta?["status"] == "reused" ? "reused" : "applied"
                logger.log("host_share_root_prepared", fields: [
                    "host_real_path": hostShareRoot,
                    "status": status,
                    "mode": "startup"
                ])
                return
            }

            let errorMessage = response.error?.message ?? response.stderr ?? "host_share_prepare failed"
            logger.log("host_share_root_prepare_failed", fields: [
                "host_real_path": hostShareRoot,
                "error": errorMessage,
                "exit_code": String(exitCode)
            ])
        } catch {
            logger.log("host_share_root_prepare_failed", fields: [
                "host_real_path": hostShareRoot,
                "error": String(describing: error)
            ])
        }
    }

    private func resolveConfiguredHostShareRoot() -> String {
        let raw = ProcessInfo.processInfo.environment["MSL_HOST_SHARE_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty, raw.hasPrefix("/") else {
            return "/"
        }
        return raw
    }

    private func handlePtyWrite(_ request: RuntimeControlRequest) -> RuntimeControlResponse {
        guard let client = initClient else {
            return RuntimeControlResponse(ok: false, error: "init channel not available")
        }
        guard let ptyId = request.ptyId, let b64 = request.dataBase64,
              let data = Data(base64Encoded: b64) else {
            return RuntimeControlResponse(ok: false, error: "missing ptyId or dataBase64")
        }
        noteGuestActivity()
        do {
            let resp = try client.ptyWrite(ptyId: ptyId, data: data, timeoutMs: request.timeoutMs ?? 2_000)
            return RuntimeControlResponse(ok: resp.ok, error: resp.error?.message)
        } catch {
            return RuntimeControlResponse(ok: false, error: String(describing: error))
        }
    }

    private func handlePtyResize(_ request: RuntimeControlRequest) -> RuntimeControlResponse {
        guard let client = initClient else {
            return RuntimeControlResponse(ok: false, error: "init channel not available")
        }
        guard let ptyId = request.ptyId, let rows = request.rows, let cols = request.cols else {
            return RuntimeControlResponse(ok: false, error: "missing ptyId/rows/cols")
        }
        do {
            let resp = try client.ptyResize(ptyId: ptyId, rows: rows, cols: cols, timeoutMs: 300)
            return RuntimeControlResponse(ok: resp.ok, error: resp.error?.message)
        } catch {
            return RuntimeControlResponse(ok: false, error: String(describing: error))
        }
    }

    private func handlePtyClose(_ request: RuntimeControlRequest) -> RuntimeControlResponse {
        guard let client = initClient else {
            return RuntimeControlResponse(ok: false, error: "init channel not available")
        }
        guard let ptyId = request.ptyId else {
            return RuntimeControlResponse(ok: false, error: "missing ptyId")
        }
        do {
            let resp = try client.ptyClose(ptyId: ptyId, timeoutMs: 500)
            return RuntimeControlResponse(ok: resp.ok, error: resp.error?.message, exitCode: resp.exitCode)
        } catch {
            return RuntimeControlResponse(ok: false, error: String(describing: error))
        }
    }

    // MARK: - Session Management

    private func handleSessionRegister() -> RuntimeControlResponse {
        let sessionID = UUID().uuidString
        do {
            try lock.withExclusiveLock {
                let session = SessionEntry(id: sessionID, pid: Int32(getpid()), startedAtEpochMs: nowEpochMs())
                let updated = try sessions.addSession(session)
                var state = try store.loadState()
                state.activeSessionCount = updated.count
                state.idleTimer = IdleTimerState(armed: false, deadlineEpochMs: nil)
                try store.saveState(state)
            }
            noteGuestActivity()
            disarmIdleTimer()
            logger.log("daemon_client_connected", fields: ["session": sessionID])
            return RuntimeControlResponse(ok: true, sessionId: sessionID)
        } catch {
            return RuntimeControlResponse(ok: false, error: String(describing: error))
        }
    }

    private func handleSessionUnregister(_ request: RuntimeControlRequest) -> RuntimeControlResponse {
        guard let sessionID = request.sessionId else {
            return RuntimeControlResponse(ok: false, error: "missing sessionId")
        }
        do {
            let remainingCount: Int = try lock.withExclusiveLock {
                let updated = try sessions.removeSession(id: sessionID)
                var state = try store.loadState()
                state.activeSessionCount = updated.count
                if updated.isEmpty {
                    let timeoutMs = resolveIdleTimeoutMs()
                    let deadline = nowEpochMs() + timeoutMs
                    state.idleTimer = IdleTimerState(armed: true, deadlineEpochMs: deadline)
                } else {
                    state.idleTimer = IdleTimerState(armed: false, deadlineEpochMs: nil)
                }
                try store.saveState(state)
                return updated.count
            }
            logger.log("daemon_client_disconnected", fields: ["session": sessionID])

            // Check if we should arm idle timer
            if remainingCount == 0 {
                armIdleTimer()
            }

            return RuntimeControlResponse(ok: true)
        } catch {
            return RuntimeControlResponse(ok: false, error: String(describing: error))
        }
    }

    // MARK: - Port Forwarding

    private func handlePortAdd(_ request: RuntimeControlRequest) -> RuntimeControlResponse {
        guard let hostPort = request.hostPort, let guestPort = request.guestPort,
              let fw = forwarder else {
            return RuntimeControlResponse(ok: false, error: "missing hostPort/guestPort")
        }
        let response = fw.add(PortMapping(hostPort: hostPort, guestPort: guestPort))
        schedulePortMappingsRefresh(reason: "manual_add")
        return response
    }

    private func handlePortRemove(_ request: RuntimeControlRequest) -> RuntimeControlResponse {
        guard let hostPort = request.hostPort, let fw = forwarder else {
            return RuntimeControlResponse(ok: false, error: "missing hostPort")
        }
        let response = fw.remove(hostPort: hostPort)
        schedulePortMappingsRefresh(reason: "manual_remove")
        return response
    }

    private func handlePortList() -> RuntimeControlResponse {
        guard let fw = forwarder else {
            return RuntimeControlResponse(ok: false, error: "forwarder unavailable")
        }
        let snapshot = currentEffectivePortMappingsSnapshot()
        return fw.list(mappings: snapshot.mappings)
    }

    private func handleMemoryStatus() -> RuntimeControlResponse {
        guard let _ = initClient else {
            return RuntimeControlResponse(ok: false, error: "init channel not available")
        }
        guard let balloon = vmRunner?.memoryBalloonRuntimeStats() else {
            return RuntimeControlResponse(ok: false, error: "balloon stats unavailable")
        }

        let reclaim = readGuestMemoryReclaimStats()
        return RuntimeControlResponse(ok: true, meta: [
            "allocated_bytes": String(balloon.allocatedBytes),
            "max_bytes": String(balloon.maxBytes),
            "returned_total_bytes": String(balloon.returnedTotalBytes),
            "compact_count": String(reclaim.compactCount),
            "compact_last_epoch_ms": reclaim.compactLastEpochMs.map(String.init) ?? "",
            "drop_cache_count": String(reclaim.dropCacheCount),
            "drop_cache_last_epoch_ms": reclaim.dropCacheLastEpochMs.map(String.init) ?? ""
        ])
    }

    private func handleDNSStatus() -> RuntimeControlResponse {
        dnsStateLock.lock()
        defer { dnsStateLock.unlock() }
        return RuntimeControlResponse(ok: true, meta: runtimeDNSMeta)
    }

    private func handleDNSReconcile(_ request: RuntimeControlRequest) -> RuntimeControlResponse {
        dnsReconcileLock.lock()
        defer { dnsReconcileLock.unlock() }
        guard let client = initClient else {
            return RuntimeControlResponse(ok: false, error: "init channel not available")
        }
        guard let metadataURL = runtimeMetadataURL else {
            return RuntimeControlResponse(ok: false, error: "runtime metadata unavailable")
        }

        let dnsSource = request.dnsSource?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? request.dnsSource!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "manual"
        logger.log("dns_reconcile_started", fields: ["dns_source": dnsSource])

        do {
            let metadata = try distributionManager.readOrRebuildInstanceMetadata(at: metadataURL)
            let config = try defaultInstanceStore.loadConfig()
            let snapshot = HostResolverSnapshotProvider().capture()
            let policy = try DNSPolicyResolver().resolve(
                instancePolicy: metadata.networkPolicy?.dns,
                globalConfig: config.network?.dns,
                hostSnapshot: snapshot
            )
            if policy.mode == .manual {
                logger.log("dns_override_applied", fields: [
                    "dns_mode": "manual",
                    "nameserver_count": String(policy.nameservers.count),
                    "search_domain_count": String(policy.searchDomains.count)
                ])
            }

            if policy.mode == .unmanaged {
                lastHostResolverSnapshotHash = snapshot.hash
                return updateDNSStateAndRespond(
                    mode: policy.mode.rawValue,
                    status: "healthy",
                    action: "policy_skip",
                    source: dnsSource,
                    nameserverCount: 0,
                    searchDomainCount: 0,
                    snapshotHash: snapshot.hash,
                    errorClass: nil,
                    error: nil
                )
            }

            let applyResp = try client.send(InitChannelRequest(
                op: "dns_reconcile",
                timeoutMs: 3_000,
                dnsMode: policy.mode.rawValue,
                dnsNameservers: policy.nameservers,
                dnsSearchDomains: policy.searchDomains,
                dnsResolverBackend: policy.resolverBackend,
                dnsSource: dnsSource,
                dnsProxyUpstreams: policy.mode == .host ? policy.nameservers : nil,
                dnsProxyListenAddress: policy.mode == .host ? "127.0.0.1" : nil,
                dnsProxyListenPort: policy.mode == .host ? 53 : nil
            ))
            let applyResult: Bool
            let applyError: String?
            if applyResp.error?.code == .unsupportedOp {
                let fallback = applyDNSReconcileLegacy(client: client, policy: policy)
                applyResult = fallback.ok
                applyError = fallback.error
            } else {
                applyResult = applyResp.ok
                applyError = applyResp.error?.message
            }

            if !applyResult {
                return updateDNSStateAndRespond(
                    mode: policy.mode.rawValue,
                    status: "failed",
                    action: "applied",
                    source: dnsSource,
                    nameserverCount: policy.nameservers.count,
                    searchDomainCount: policy.searchDomains.count,
                    snapshotHash: snapshot.hash,
                    errorClass: "init_channel",
                    error: applyError ?? "dns_reconcile failed"
                )
            }

            let transportReady = ensureGuestTransportReadyViaExec(client: client)
            if !transportReady.ok {
                return updateDNSStateAndRespond(
                    mode: policy.mode.rawValue,
                    status: "degraded",
                    action: "applied",
                    source: dnsSource,
                    nameserverCount: policy.nameservers.count,
                    searchDomainCount: policy.searchDomains.count,
                    snapshotHash: snapshot.hash,
                    errorClass: "network_transport",
                    error: transportReady.error ?? "guest transport bootstrap failed"
                )
            }

            let healthResp = try client.send(InitChannelRequest(
                op: "dns_healthcheck",
                timeoutMs: 2_000,
                dnsMode: policy.mode.rawValue,
                dnsSource: dnsSource
            ))
            let healthResult: Bool
            let healthError: String?
            if healthResp.error?.code == .unsupportedOp {
                let fallback = runDNSHealthcheckLegacy(client: client)
                healthResult = fallback.ok
                healthError = fallback.error
            } else {
                healthResult = healthResp.ok
                healthError = healthResp.error?.message
            }
            if !healthResult {
                let healthErrorClass = classifyDNSHealthcheckError(healthError)
                logger.log("dns_healthcheck_failed", fields: [
                    "dns_mode": policy.mode.rawValue,
                    "dns_source": dnsSource,
                    "error_class": healthErrorClass,
                    "error": healthError ?? "dns healthcheck failed"
                ])
                return updateDNSStateAndRespond(
                    mode: policy.mode.rawValue,
                    status: "degraded",
                    action: "applied",
                    source: dnsSource,
                    nameserverCount: policy.nameservers.count,
                    searchDomainCount: policy.searchDomains.count,
                    snapshotHash: snapshot.hash,
                    errorClass: healthErrorClass,
                    error: healthError ?? "dns healthcheck failed"
                )
            }

            return updateDNSStateAndRespond(
                mode: policy.mode.rawValue,
                status: "healthy",
                action: "applied",
                source: dnsSource,
                nameserverCount: policy.nameservers.count,
                searchDomainCount: policy.searchDomains.count,
                snapshotHash: snapshot.hash,
                errorClass: nil,
                error: nil
            )
        } catch {
            logger.log("dns_override_invalid", fields: [
                "dns_source": dnsSource,
                "error": String(describing: error)
            ])
            return updateDNSStateAndRespond(
                mode: "unknown",
                status: "failed",
                action: "-",
                source: dnsSource,
                nameserverCount: 0,
                searchDomainCount: 0,
                snapshotHash: "",
                errorClass: "config_invalid",
                error: String(describing: error)
            )
        }
    }

    private func updateDNSStateAndRespond(
        mode: String,
        status: String,
        action: String,
        source: String,
        nameserverCount: Int,
        searchDomainCount: Int,
        snapshotHash: String,
        errorClass: String?,
        error: String?
    ) -> RuntimeControlResponse {
        let now = nowEpochMs()
        var meta: [String: String] = [
            "dns_mode": mode,
            "dns_status": status,
            "dns_action": action,
            "dns_source": source,
            "nameserver_count": String(nameserverCount),
            "search_domain_count": String(searchDomainCount),
            "snapshot_hash": snapshotHash,
            "last_reconcile_epoch_ms": String(now)
        ]
        if let errorClass, !errorClass.isEmpty {
            meta["error_class"] = errorClass
        }
        if let error, !error.isEmpty {
            meta["error"] = error
        }
        dnsStateLock.lock()
        runtimeDNSMeta = meta
        dnsStateLock.unlock()
        if !snapshotHash.isEmpty {
            lastHostResolverSnapshotHash = snapshotHash
        }

        let event: String
        if action == "policy_skip" {
            event = "dns_reconcile_skipped"
        } else if status == "healthy" {
            event = "dns_reconcile_succeeded"
        } else {
            event = "dns_reconcile_failed"
        }
        logger.log(event, fields: meta)
        return RuntimeControlResponse(ok: status != "failed", error: error, meta: meta)
    }

    private func classifyDNSHealthcheckError(_ error: String?) -> String {
        guard let error else {
            return "dns_resolution"
        }
        let lowered = error.lowercased()
        if lowered.contains("network transport unavailable")
            || lowered.contains("missing default route")
            || lowered.contains("network is unreachable") {
            return "network_transport"
        }
        return "dns_resolution"
    }

    private func currentDNSMetaSnapshot() -> [String: String] {
        dnsStateLock.lock()
        defer { dnsStateLock.unlock() }
        return runtimeDNSMeta
    }

    private func ensureGuestTransportReadyViaExec(client: InitChannelClient) -> (ok: Bool, error: String?) {
        let script = """
        set -eu
        UDHCP_SCRIPT=/tmp/msl-udhcpc-script.sh
        cat > "$UDHCP_SCRIPT" <<'EOF'
        #!/bin/sh
        set -eu
        case "$1" in
          deconfig)
            if command -v ifconfig >/dev/null 2>&1; then
              ifconfig "$interface" 0.0.0.0 up >/dev/null 2>&1 || true
            elif command -v busybox >/dev/null 2>&1; then
              busybox ifconfig "$interface" 0.0.0.0 up >/dev/null 2>&1 || true
            else
              ip link set dev "$interface" up >/dev/null 2>&1 || true
              ip -4 addr flush dev "$interface" scope global >/dev/null 2>&1 || true
            fi
            ;;
          renew|bound)
            if command -v ifconfig >/dev/null 2>&1; then
              ifconfig "$interface" "$ip" netmask "${subnet:-255.255.255.0}" up >/dev/null 2>&1 || true
            elif command -v busybox >/dev/null 2>&1; then
              busybox ifconfig "$interface" "$ip" netmask "${subnet:-255.255.255.0}" up >/dev/null 2>&1 || true
            else
              ip link set dev "$interface" up >/dev/null 2>&1 || true
              ip -4 addr flush dev "$interface" scope global >/dev/null 2>&1 || true
              ip -4 addr add "$ip/24" dev "$interface" >/dev/null 2>&1 || true
            fi
            ip route del default dev "$interface" >/dev/null 2>&1 || true
            for r in $router; do
              ip route add default via "$r" dev "$interface" >/dev/null 2>&1 && break
            done
            ;;
        esac
        exit 0
        EOF
        chmod 0755 "$UDHCP_SCRIPT"
        has_transport() {
          ip -4 route show default 2>/dev/null | grep -q '^default' || return 1
          ip -4 -o addr show scope global 2>/dev/null | grep -q 'inet ' || return 1
          return 0
        }
        has_transport && exit 0
        for iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -Ev '^(lo|sit|ip6tnl)' || true); do
          if command -v sudo >/dev/null 2>&1; then
            sudo -n ip link set dev "$iface" up >/dev/null 2>&1 || true
          else
            ip link set dev "$iface" up >/dev/null 2>&1 || true
          fi
          if ip -4 -o addr show dev "$iface" scope global 2>/dev/null | grep -q 'inet '; then
            continue
          fi
          if command -v udhcpc >/dev/null 2>&1; then
            if command -v sudo >/dev/null 2>&1; then
              sudo -n udhcpc -i "$iface" -n -q -t 3 -T 1 -s "$UDHCP_SCRIPT" >/dev/null 2>&1 || true
            else
              udhcpc -i "$iface" -n -q -t 3 -T 1 -s "$UDHCP_SCRIPT" >/dev/null 2>&1 || true
            fi
          elif command -v busybox >/dev/null 2>&1; then
            if command -v sudo >/dev/null 2>&1; then
              sudo -n busybox udhcpc -i "$iface" -n -q -t 3 -T 1 -s "$UDHCP_SCRIPT" >/dev/null 2>&1 || true
            else
              busybox udhcpc -i "$iface" -n -q -t 3 -T 1 -s "$UDHCP_SCRIPT" >/dev/null 2>&1 || true
            fi
          elif command -v dhclient >/dev/null 2>&1; then
            if command -v sudo >/dev/null 2>&1; then
              sudo -n dhclient -4 -1 "$iface" >/dev/null 2>&1 || true
            else
              dhclient -4 -1 "$iface" >/dev/null 2>&1 || true
            fi
          fi
          has_transport && exit 0
        done
        has_transport
        """

        do {
            let response = try client.send(InitChannelRequest(
                op: "exec",
                argv: ["/bin/sh", "-lc", script],
                timeoutMs: 8_000
            ))
            if response.ok, (response.exitCode ?? 1) == 0 {
                return (true, nil)
            }
            let error = response.error?.message ?? response.stderr ?? "missing default route or ipv4 address"
            return (false, "network transport unavailable: \(error)")
        } catch {
            return (false, "network transport bootstrap init_channel error: \(error)")
        }
    }

    private func maybeReconcileDNSBeforeGuestOperation() {
        let meta = currentDNSMetaSnapshot()
        if meta["dns_mode"] == "unmanaged" {
            return
        }
        let now = nowEpochMs()
        let lastReconcileMs = Int64(meta["last_reconcile_epoch_ms"] ?? "0") ?? 0
        let snapshot = HostResolverSnapshotProvider().capture()
        let lastHash = meta["snapshot_hash"] ?? ""
        if !lastHash.isEmpty && snapshot.hash != lastHash {
            _ = handleDNSReconcile(RuntimeControlRequest(op: "dns_reconcile", dnsSource: "stale_guard"))
            return
        }
        if now - lastReconcileMs >= 60_000 {
            _ = handleDNSReconcile(RuntimeControlRequest(op: "dns_reconcile", dnsSource: "stale_guard"))
        }
    }

    private func startDNSMonitorLoop() {
        stopDNSMonitorLoop()
        let source = DispatchSource.makeTimerSource(queue: dnsMonitorQueue)
        source.schedule(deadline: .now() + .seconds(5), repeating: .seconds(5))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let meta = self.currentDNSMetaSnapshot()
            if meta["dns_mode"] == "unmanaged" {
                return
            }
            let snapshot = HostResolverSnapshotProvider().capture()
            if self.lastHostResolverSnapshotHash == nil {
                self.lastHostResolverSnapshotHash = snapshot.hash
                return
            }
            if self.lastHostResolverSnapshotHash != snapshot.hash {
                _ = self.handleDNSReconcile(RuntimeControlRequest(op: "dns_reconcile", dnsSource: "host_change"))
            }
        }
        source.resume()
        dnsMonitorTimer = source
    }

    private func stopDNSMonitorLoop() {
        dnsMonitorTimer?.cancel()
        dnsMonitorTimer = nil
    }

    private func applyDNSReconcileLegacy(client: InitChannelClient, policy: ResolvedDNSPolicy) -> (ok: Bool, error: String?) {
        var lines: [String] = [
            "# Generated by msl (step21)",
            "# mode: \(policy.mode.rawValue)"
        ]
        for ns in policy.nameservers {
            lines.append("nameserver \(ns)")
        }
        if !policy.searchDomains.isEmpty {
            lines.append("search \(policy.searchDomains.joined(separator: " "))")
        }
        let payload = lines
            .map { $0.replacingOccurrences(of: "'", with: "'\\''") }
            .joined(separator: "\\n")
        let writeCmd = "tmp=/etc/resolv.conf.msl.tmp; printf '%b\\n' '\(payload)' > \\\"$tmp\\\"; mv \\\"$tmp\\\" /etc/resolv.conf"
        let script = """
        set -eu
        if command -v sudo >/dev/null 2>&1; then
          sudo -n sh -c '\(writeCmd)'
        elif command -v su >/dev/null 2>&1; then
          su -c '\(writeCmd)'
        else
          sh -c '\(writeCmd)'
        fi
        """

        do {
            let response = try client.send(InitChannelRequest(
                op: "exec",
                argv: ["/bin/sh", "-lc", script],
                timeoutMs: 4_000
            ))
            if response.ok, (response.exitCode ?? 1) == 0 {
                return (true, nil)
            }
            return (false, response.error?.message ?? response.stderr ?? "legacy dns apply failed")
        } catch {
            return (false, String(describing: error))
        }
    }

    private func runDNSHealthcheckLegacy(client: InitChannelClient) -> (ok: Bool, error: String?) {
        let script = """
        set -eu
        for domain in www.msftconnecttest.com archive.ubuntu.com dl-cdn.alpinelinux.org; do
          if getent hosts "$domain" >/dev/null 2>&1; then
            exit 0
          fi
        done
        exit 1
        """
        do {
            let response = try client.send(InitChannelRequest(
                op: "exec",
                argv: ["/bin/sh", "-lc", script],
                timeoutMs: 2_000
            ))
            if response.ok, (response.exitCode ?? 1) == 0 {
                return (true, nil)
            }
            return (false, response.error?.message ?? response.stderr ?? "dns healthcheck failed")
        } catch {
            return (false, String(describing: error))
        }
    }

    // MARK: - Stop

    private func handleStop() -> RuntimeControlResponse {
        logger.log("daemon_stopping", fields: ["reason": "explicit_stop"])
        // Signal the daemon to shut down after sending this response
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            self?.stopSemaphore.signal()
        }
        return RuntimeControlResponse(ok: true)
    }

    // MARK: - Idle Timer

    private func armIdleTimer() {
        disarmIdleTimer()
        let timeoutMs = resolveIdleTimeoutMs()
        logger.log("idle_timer_armed", fields: ["timeout_ms": String(timeoutMs)])

        let source = DispatchSource.makeTimerSource(queue: idleTimerQueue)
        source.schedule(deadline: .now() + .milliseconds(Int(timeoutMs)))
        source.setEventHandler { [weak self] in
            self?.handleIdleExpiry()
        }
        source.resume()
        idleTimerSource = source
    }

    private func disarmIdleTimer() {
        idleTimerSource?.cancel()
        idleTimerSource = nil
    }

    private func handleIdleExpiry() {
        do {
            let shouldStop = try lock.withExclusiveLock { () -> Bool in
                let alive = try sessions.reconcile()
                if !alive.isEmpty {
                    // Sessions appeared, cancel
                    var state = try store.loadState()
                    state.activeSessionCount = alive.count
                    state.idleTimer = IdleTimerState(armed: false, deadlineEpochMs: nil)
                    try store.saveState(state)
                    return false
                }
                return true
            }
            if shouldStop {
                logger.log("daemon_stopping", fields: ["reason": "idle_timeout"])
                stopSemaphore.signal()
            }
        } catch {
            logger.log("idle_timer_check_error", fields: ["error": String(describing: error)])
        }
    }

    // MARK: - Shutdown

    private func shutdown() {
        stopDNSMonitorLoop()
        stopAutoPortForwardLoop()
        stopMemoryReclaimLoop()
        controlServer?.stop()
        forwarder?.stopAll()
        vmRunner?.stopRunningVM()
        updateStateStopped()
        logger.log("daemon_stopped")
    }

    private func updateStateStopped() {
        do {
            try lock.withExclusiveLock {
                var state = try store.loadState()
                state.vmState = .stopped
                state.activeSessionCount = 0
                state.idleTimer = IdleTimerState(armed: false, deadlineEpochMs: nil)
                state.lastTransitionEpochMs = nowEpochMs()
                state.runtimeHostPid = nil
                state.runtimeControlSocket = nil
                state.runtimeUser = nil
                try store.saveState(state)
                try sessions.clearAllAndTerminate()
            }
        } catch {
            logger.log("daemon_state_cleanup_error", fields: ["error": String(describing: error)])
        }
    }

    private func convergeRuntimeUser(
        client: InitChannelClient,
        metadataURL: URL,
        instanceName: String
    ) throws -> ConvergedRuntimeUserResult {
        let policy = try distributionManager.resolveUserConvergencePolicy(metadataURL: metadataURL)
        let hostUser = resolveHostUserContext(policy: policy)

        logger.log("user_convergence_started", fields: [
            "instance": instanceName,
            "metadata": metadataURL.path,
            "template_id": policy.templateId,
            "command_family": policy.commandFamily,
            "username": hostUser.username,
            "uid": String(hostUser.uid),
            "gid": String(hostUser.gid)
        ])

        let response = try client.convergeUser(
            spec: hostUser,
            policy: policy,
            instanceName: instanceName,
            timeoutMs: 20_000
        )
        guard response.ok else {
            let code = response.error?.code.rawValue ?? "internal_error"
            let message = response.error?.message ?? "converge_user failed"
            throw MSLRuntimeError("user convergence failed (\(code)): \(message)")
        }

        let meta = response.meta ?? [:]
        let name = meta["resolved_user"] ?? hostUser.username
        let uid = Int(meta["resolved_uid"] ?? "") ?? hostUser.uid
        let gid = Int(meta["resolved_gid"] ?? "") ?? hostUser.gid
        let home = meta["resolved_home"] ?? hostUser.home
        let shell = meta["resolved_shell"] ?? (policy.shellFallbacks.first ?? "/bin/sh")
        let resolvedTemplateID = meta["policy_template_id"] ?? policy.templateId

        if let warnings = meta["warnings"], !warnings.isEmpty {
            logger.log("user_convergence_degraded", fields: [
                "instance": instanceName,
                "warnings": warnings
            ])
        }
        logger.log("user_convergence_succeeded", fields: [
            "instance": instanceName,
            "resolved_user": name,
            "resolved_uid": String(uid),
            "resolved_gid": String(gid),
            "resolved_shell": shell,
            "template_id": resolvedTemplateID
        ])
        logger.log("runtime_user_selected", fields: [
            "instance": instanceName,
            "username": name,
            "uid": String(uid),
            "gid": String(gid),
            "home": home,
            "shell": shell
        ])

        let runtimeUser = RuntimeUserState(
            name: name,
            uid: uid,
            gid: gid,
            home: home,
            shell: shell,
            policyTemplateID: resolvedTemplateID,
            lastConvergedEpochMs: nowEpochMs()
        )
        return ConvergedRuntimeUserResult(runtimeUser: runtimeUser, adminGroup: policy.adminGroup)
    }

    private func resolveHostUserContext(policy: UserConvergencePolicy) -> InitConvergeUserSpec {
        let env = ProcessInfo.processInfo.environment
        let forceRoot = env["MSL_RUNTIME_USER_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if forceRoot == "1" || forceRoot == "true" || forceRoot == "yes" {
            return InitConvergeUserSpec(
                username: "root",
                uid: 0,
                gid: 0,
                home: "/root",
                preferredShell: "/bin/sh",
                failOnUIDConflict: false
            )
        }
        let envUser = env["USER"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let userName = (envUser?.isEmpty == false ? envUser! : NSUserName())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeUser = userName.isEmpty ? "msl" : userName
        let home = "/home/\(safeUser)"
        let preferredShell = policy.shellFallbacks.first

        return InitConvergeUserSpec(
            username: safeUser,
            uid: Int(getuid()),
            gid: Int(getgid()),
            home: home,
            preferredShell: preferredShell,
            failOnUIDConflict: true
        )
    }

    // MARK: - Helpers

    private func startAutoPortForwardLoop() {
        stopAutoPortForwardLoop()

        let timer = DispatchSource.makeTimerSource(queue: autoPortQueue)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(5))
        timer.setEventHandler { [weak self] in
            self?.syncAutoPortMappingsTick()
        }
        timer.resume()
        autoPortTimer = timer

        autoPortQueue.async { [weak self] in
            self?.syncAutoPortMappingsTick()
        }
    }

    private func stopAutoPortForwardLoop() {
        autoPortTimer?.cancel()
        autoPortTimer = nil
        portMappingsSnapshotLock.lock()
        autoPortErrorsByHostPort.removeAll()
        portMappingsSnapshotLock.unlock()
    }

    private func syncAutoPortMappingsTick() {
        guard let client = initClient else {
            return
        }
        guard let autoHostPorts = probeAutoForwardHostPorts(client: client) else {
            return
        }
        syncEffectivePortMappings(autoHostPorts: autoHostPorts, reason: "auto_probe")
    }

    private func schedulePortMappingsRefresh(reason: String) {
        autoPortQueue.async { [weak self] in
            guard let self else { return }
            if let client = self.initClient,
               let autoHostPorts = self.probeAutoForwardHostPorts(client: client) {
                self.syncEffectivePortMappings(autoHostPorts: autoHostPorts, reason: reason)
                return
            }
            let current = self.currentEffectivePortMappingsSnapshot()
            self.syncEffectivePortMappings(autoHostPorts: current.autoHostPorts, reason: reason)
        }
    }

    private func syncEffectivePortMappings(autoHostPorts: Set<Int>, reason: String) {
        guard let fw = forwarder else {
            return
        }

        let manualMappings: [PortMapping]
        do {
            manualMappings = try lock.withExclusiveLock(timeoutSec: 1) {
                try store.loadPortMappings().mappings
            }
        } catch {
            logger.log("daemon_port_preload_failed", fields: ["error": String(describing: error)])
            return
        }

        let previous = currentEffectivePortMappingsSnapshot()
        let effective = AutoPortForwardingPlanner.merge(
            manualMappings: manualMappings,
            autoHostPorts: autoHostPorts
        )
        setEffectivePortMappingsSnapshot(effective)

        let result = fw.sync(mappings: effective.mappings)
        logAutoPortDiff(previous: previous, current: effective, statusItems: result.items ?? [], reason: reason)
    }

    private func probeAutoForwardHostPorts(client: InitChannelClient) -> Set<Int>? {
        do {
            let response = try client.send(InitChannelRequest(
                op: "exec",
                argv: ["/bin/cat", "/proc/net/tcp"],
                timeoutMs: 1_500
            ))
            guard response.ok else {
                logger.log("auto_port_probe_failed", fields: [
                    "reason": response.error?.message ?? "exec_failed"
                ])
                return nil
            }
            return GuestListeningPortDetector.discoverableHostPorts(fromProcNetTCP: response.stdout ?? "")
        } catch {
            logger.log("auto_port_probe_failed", fields: ["reason": String(describing: error)])
            return nil
        }
    }

    private func logAutoPortDiff(
        previous: EffectivePortMappings,
        current: EffectivePortMappings,
        statusItems: [RuntimePortStatusItem],
        reason: String
    ) {
        let previousErrors: [Int: String]
        portMappingsSnapshotLock.lock()
        previousErrors = autoPortErrorsByHostPort
        portMappingsSnapshotLock.unlock()

        let added = current.autoHostPorts.subtracting(previous.autoHostPorts).sorted()
        for hostPort in added {
            logger.log("auto_port_detected", fields: [
                "hostPort": String(hostPort),
                "reason": reason
            ])
        }

        let removed = previous.autoHostPorts.subtracting(current.autoHostPorts).sorted()
        for hostPort in removed {
            logger.log("auto_port_removed", fields: [
                "hostPort": String(hostPort),
                "reason": reason
            ])
        }

        var nextErrors: [Int: String] = [:]
        for item in statusItems where current.autoHostPorts.contains(item.hostPort) {
            guard let error = item.error, !error.isEmpty else {
                continue
            }
            nextErrors[item.hostPort] = error
            if previousErrors[item.hostPort] != error {
                logger.log("auto_port_conflict", fields: [
                    "hostPort": String(item.hostPort),
                    "guestPort": String(item.guestPort),
                    "error": error
                ])
            }
        }
        portMappingsSnapshotLock.lock()
        autoPortErrorsByHostPort = nextErrors
        portMappingsSnapshotLock.unlock()
    }

    private func currentEffectivePortMappingsSnapshot() -> EffectivePortMappings {
        portMappingsSnapshotLock.lock()
        defer { portMappingsSnapshotLock.unlock() }
        return effectivePortMappingsSnapshot
    }

    private func setEffectivePortMappingsSnapshot(_ snapshot: EffectivePortMappings) {
        portMappingsSnapshotLock.lock()
        effectivePortMappingsSnapshot = snapshot
        portMappingsSnapshotLock.unlock()
    }

    private func configureMemoryReclaimPolicy() {
        do {
            let config = try defaultInstanceStore.loadConfig()
            let resolution = MemoryReclaimPolicyResolver.resolve(config: config.memory)
            memoryReclaimPolicy = resolution.policy
            for warning in resolution.warnings {
                logger.log("memory_reclaim_policy_warning", fields: ["warning": warning])
            }
        } catch {
            memoryReclaimPolicy = .defaultPolicy
            logger.log("memory_reclaim_policy_warning", fields: [
                "warning": "failed_to_load_config",
                "error": String(describing: error)
            ])
        }
        logger.log("memory_reclaim_policy_resolved", fields: [
            "shortIdle": memoryReclaimPolicy.shortIdle.rawValue,
            "longIdle": memoryReclaimPolicy.longIdle.rawValue,
            "hostPressure": memoryReclaimPolicy.hostPressure.rawValue,
            "cacheCleanThresholdMB": String(memoryReclaimPolicy.cacheCleanThresholdMB),
            "cooldownDurationS": String(memoryReclaimPolicy.cacheCleanupCooldownMs / 1_000),
            "hysteresisPercent": String(memoryReclaimPolicy.cacheCleanupHysteresisPercent)
        ])
    }

    private func ensureGuestMSLCommandAlias(client: InitChannelClient) {
        do {
            let response = try client.send(InitChannelRequest(
                op: "exec",
                argv: [
                    "/bin/sh",
                    "-lc",
                    "mkdir -p /usr/local/bin; ln -sf /usr/local/bin/msl-init /usr/local/bin/msl"
                ],
                timeoutMs: 2_000
            ))
            guard response.ok else {
                logger.log("guest_msl_alias_ensure_failed", fields: [
                    "error": response.error?.message ?? "exec_failed"
                ])
                return
            }
            logger.log("guest_msl_alias_ensured")
        } catch {
            logger.log("guest_msl_alias_ensure_failed", fields: ["error": String(describing: error)])
        }
    }

    private func noteGuestActivity() {
        let now = nowEpochMs()
        reclaimStateQueue.sync {
            lastGuestActivityEpochMs = now
        }
    }

    private func startMemoryReclaimLoop() {
        stopMemoryReclaimLoop()
        reclaimStateQueue.sync {
            lastGuestActivityEpochMs = nowEpochMs()
            lastShortIdleReclaimEpochMs = nil
            lastLongIdleReclaimEpochMs = nil
            lastHostPressureReclaimEpochMs = nil
            lastCacheCapReclaimEpochMs = nil
            cacheOverCapActive = false
        }

        let timer = DispatchSource.makeTimerSource(queue: memoryReclaimQueue)
        timer.schedule(
            deadline: .now() + .seconds(MemoryReclaimPolicyResolver.periodicPollIntervalSec),
            repeating: .seconds(MemoryReclaimPolicyResolver.periodicPollIntervalSec)
        )
        timer.setEventHandler { [weak self] in
            self?.evaluateMemoryReclaimOnTimer()
        }
        timer.resume()
        memoryReclaimTimer = timer

#if canImport(Darwin)
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: memoryReclaimQueue
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let event = source.data
            let level: String
            if event.contains(.critical) {
                level = "critical"
            } else if event.contains(.warning) {
                level = "warning"
            } else {
                level = "unknown"
            }
            self.handleHostMemoryPressure(level: level)
        }
        source.resume()
        hostMemoryPressureSource = source
#endif
    }

    private func stopMemoryReclaimLoop() {
        memoryReclaimTimer?.cancel()
        memoryReclaimTimer = nil
#if canImport(Darwin)
        hostMemoryPressureSource?.cancel()
        hostMemoryPressureSource = nil
#endif
    }

    private func evaluateMemoryReclaimOnTimer() {
        let now = nowEpochMs()
        let snapshot = reclaimStateQueue.sync { () -> (Int64, Int64?, Int64?, Int64?, Int64?) in
            (
                lastGuestActivityEpochMs,
                lastShortIdleReclaimEpochMs,
                lastLongIdleReclaimEpochMs,
                lastHostPressureReclaimEpochMs,
                lastCacheCapReclaimEpochMs
            )
        }
        let inactivityMs = now - snapshot.0

        if evaluateCacheCapReclaim(nowMs: now, lastCacheCapReclaimEpochMs: snapshot.4) {
            return
        }

        if MemoryReclaimPolicyResolver.shouldTriggerLongIdle(
            nowMs: now,
            lastGuestActivityEpochMs: snapshot.0,
            lastLongIdleReclaimEpochMs: snapshot.2
        ) {
            runMemoryReclaim(trigger: .longIdle, strategy: memoryReclaimPolicy.longIdle, inactivityMs: inactivityMs)
            return
        }

        guard inactivityMs >= MemoryReclaimPolicyResolver.shortIdleThresholdMs else {
            return
        }
        guard let isCPUIdle = sampleGuestCPUIdle() else {
            logger.log("memory_reclaim_skipped", fields: [
                "trigger": MemoryReclaimTrigger.shortIdle.rawValue,
                "reason": "cpu_idle_probe_failed"
            ])
            return
        }
        guard MemoryReclaimPolicyResolver.shouldTriggerShortIdle(
            nowMs: now,
            lastGuestActivityEpochMs: snapshot.0,
            lastShortIdleReclaimEpochMs: snapshot.1,
            isGuestCPUIdle: isCPUIdle
        ) else {
            return
        }

        runMemoryReclaim(trigger: .shortIdle, strategy: memoryReclaimPolicy.shortIdle, inactivityMs: inactivityMs)
    }

    private func evaluateCacheCapReclaim(nowMs: Int64, lastCacheCapReclaimEpochMs: Int64?) -> Bool {
        let cacheThresholdMB = memoryReclaimPolicy.cacheCleanThresholdMB
        guard let meminfo = sampleGuestMemInfo(),
              let cacheUsageKB = MemoryReclaimPolicyResolver.parseCacheUsageKB(meminfo) else {
            logger.log("memory_reclaim_skipped", fields: [
                "trigger": MemoryReclaimTrigger.cacheCap.rawValue,
                "reason": "cache_probe_failed"
            ])
            return false
        }

        let cacheUsageMB = cacheUsageKB / 1024
        let overCap = reclaimStateQueue.sync { () -> Bool in
            let next = MemoryReclaimPolicyResolver.isCacheOverCap(
                cacheUsageMB: cacheUsageMB,
                cacheCleanThresholdMB: cacheThresholdMB,
                hysteresisPercent: memoryReclaimPolicy.cacheCleanupHysteresisPercent,
                wasOverCap: cacheOverCapActive
            )
            cacheOverCapActive = next
            return next
        }
        logger.log("memory_reclaim_cache_eval", fields: [
            "cache_usage_mb": String(cacheUsageMB),
            "cache_clean_threshold_mb": String(cacheThresholdMB),
            "over_cap": overCap ? "1" : "0"
        ])
        guard overCap else {
            return false
        }

        guard let isCPUIdle = sampleGuestCPUIdle() else {
            logger.log("memory_reclaim_skipped", fields: [
                "trigger": MemoryReclaimTrigger.cacheCap.rawValue,
                "reason": "cpu_idle_probe_failed"
            ])
            return false
        }

        guard MemoryReclaimPolicyResolver.shouldTriggerCacheCap(
            nowMs: nowMs,
            lastCacheCapReclaimEpochMs: lastCacheCapReclaimEpochMs,
            isOverCap: overCap,
            isGuestCPUIdle: isCPUIdle,
            cooldownMs: memoryReclaimPolicy.cacheCleanupCooldownMs
        ) else {
            logger.log("memory_reclaim_skipped", fields: [
                "trigger": MemoryReclaimTrigger.cacheCap.rawValue,
                "reason": "cooldown_or_busy_cpu"
            ])
            return false
        }

        runMemoryReclaim(trigger: .cacheCap, strategy: .dropCaches, inactivityMs: nil)
        return true
    }

    private func handleHostMemoryPressure(level: String) {
        let now = nowEpochMs()
        let shouldTrigger = reclaimStateQueue.sync {
            MemoryReclaimPolicyResolver.shouldTriggerHostPressure(
                nowMs: now,
                lastHostPressureReclaimEpochMs: lastHostPressureReclaimEpochMs
            )
        }
        guard shouldTrigger else {
            logger.log("memory_reclaim_skipped", fields: [
                "trigger": MemoryReclaimTrigger.hostPressure.rawValue,
                "reason": "cooldown",
                "level": level
            ])
            return
        }
        runMemoryReclaim(trigger: .hostPressure, strategy: memoryReclaimPolicy.hostPressure, inactivityMs: nil)
    }

    private func sampleGuestCPUIdle() -> Bool? {
        guard let client = initClient else {
            return nil
        }
        do {
            let response = try client.send(InitChannelRequest(
                op: "exec",
                argv: ["/bin/cat", "/proc/loadavg"],
                timeoutMs: 1_500
            ))
            guard response.ok, let stdout = response.stdout,
                  let load1 = MemoryReclaimPolicyResolver.parseLoadAverage1(stdout) else {
                return nil
            }
            return load1 < 0.20
        } catch {
            return nil
        }
    }

    private func sampleGuestMemInfo() -> String? {
        guard let client = initClient else {
            return nil
        }
        do {
            let response = try client.send(InitChannelRequest(
                op: "exec",
                argv: ["/bin/cat", "/proc/meminfo"],
                timeoutMs: 1_500
            ))
            guard response.ok, let stdout = response.stdout else {
                return nil
            }
            return stdout
        } catch {
            return nil
        }
    }

    private func runMemoryReclaim(
        trigger: MemoryReclaimTrigger,
        strategy: MemoryReclaimStrategy,
        inactivityMs: Int64?
    ) {
        let now = nowEpochMs()
        defer {
            reclaimStateQueue.sync {
                switch trigger {
                case .shortIdle:
                    lastShortIdleReclaimEpochMs = now
                case .longIdle:
                    lastLongIdleReclaimEpochMs = now
                case .hostPressure:
                    lastHostPressureReclaimEpochMs = now
                case .cacheCap:
                    lastCacheCapReclaimEpochMs = now
                case .manual:
                    break
                }
            }
        }

        let action: String?
        switch strategy {
        case .compact:
            action = "compact"
        case .dropCaches:
            action = "drop-cache"
        case .none:
            action = nil
        }

        guard let action else {
            logger.log("memory_reclaim_skipped", fields: [
                "trigger": trigger.rawValue,
                "strategy": strategy.rawValue,
                "reason": "strategy_none"
            ])
            return
        }
        guard let client = initClient else {
            logger.log("memory_reclaim_skipped", fields: [
                "trigger": trigger.rawValue,
                "strategy": strategy.rawValue,
                "reason": "init_channel_unavailable"
            ])
            return
        }

        logger.log("memory_reclaim_triggered", fields: [
            "trigger": trigger.rawValue,
            "strategy": strategy.rawValue,
            "inactivity_ms": inactivityMs.map(String.init) ?? ""
        ])
        do {
            var response = try client.send(InitChannelRequest(
                op: "exec",
                argv: ["/usr/local/bin/msl-init", "memory", action],
                timeoutMs: 5_000
            ))
            var exitCode = response.exitCode ?? 0

            if !(response.ok && exitCode == 0), let fallback = strategy.shellCommand {
                logger.log("memory_reclaim_retry_fallback", fields: [
                    "trigger": trigger.rawValue,
                    "strategy": strategy.rawValue,
                    "error": response.error?.message ?? "guest_msl_memory_failed",
                    "exit_code": String(exitCode)
                ])
                response = try client.send(InitChannelRequest(
                    op: "exec",
                    argv: ["/bin/sh", "-lc", fallback],
                    timeoutMs: 5_000
                ))
                exitCode = response.exitCode ?? 0
            }

            if response.ok && exitCode == 0 {
                logger.log("memory_reclaim_completed", fields: [
                    "trigger": trigger.rawValue,
                    "strategy": strategy.rawValue,
                    "exit_code": String(exitCode)
                ])
            } else {
                logger.log("memory_reclaim_failed", fields: [
                    "trigger": trigger.rawValue,
                    "strategy": strategy.rawValue,
                    "error": response.error?.message ?? "exec_failed",
                    "exit_code": String(exitCode)
                ])
            }
        } catch {
            logger.log("memory_reclaim_failed", fields: [
                "trigger": trigger.rawValue,
                "strategy": strategy.rawValue,
                "error": String(describing: error)
            ])
        }
    }

    private struct GuestMemoryReclaimStats {
        var compactCount: UInt64
        var compactLastEpochMs: Int64?
        var dropCacheCount: UInt64
        var dropCacheLastEpochMs: Int64?

        static let zero = GuestMemoryReclaimStats(
            compactCount: 0,
            compactLastEpochMs: nil,
            dropCacheCount: 0,
            dropCacheLastEpochMs: nil
        )
    }

    private func readGuestMemoryReclaimStats() -> GuestMemoryReclaimStats {
        guard let client = initClient else {
            return .zero
        }
        do {
            let response = try client.send(InitChannelRequest(
                op: "exec",
                argv: ["/bin/cat", "/run/msl-memory-stats.env"],
                timeoutMs: 1_500
            ))
            guard response.ok, (response.exitCode ?? 1) == 0, let stdout = response.stdout else {
                return .zero
            }
            return parseGuestMemoryReclaimStats(stdout)
        } catch {
            return .zero
        }
    }

    private func parseGuestMemoryReclaimStats(_ text: String) -> GuestMemoryReclaimStats {
        var values: [String: String] = [:]
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let sep = line.firstIndex(of: "=") else {
                continue
            }
            let key = String(line[..<sep]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: sep)...]).trimmingCharacters(in: .whitespaces)
            values[key] = value
        }

        func parseUInt64(_ key: String) -> UInt64 {
            guard let raw = values[key], let value = UInt64(raw) else {
                return 0
            }
            return value
        }

        func parseInt64Optional(_ key: String) -> Int64? {
            guard let raw = values[key], !raw.isEmpty, let value = Int64(raw), value > 0 else {
                return nil
            }
            return value
        }

        return GuestMemoryReclaimStats(
            compactCount: parseUInt64("compact_count"),
            compactLastEpochMs: parseInt64Optional("compact_last_epoch_ms"),
            dropCacheCount: parseUInt64("drop_cache_count"),
            dropCacheLastEpochMs: parseInt64Optional("drop_cache_last_epoch_ms")
        )
    }

    private func resolveIdleTimeoutMs() -> Int64 {
        if let raw = ProcessInfo.processInfo.environment["MSL_IDLE_TIMEOUT_MS"],
           let val = Int64(raw), val > 0 {
            return val
        }
        if !FileManager.default.fileExists(atPath: paths.mslHostInitBootstrapLogFile.path) {
            return 300_000  // 5 min (first provisioning)
        }
        return 120_000  // 2 min (warm VM default)
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
}

private func daemonMonotonicMs() -> Int64 {
    Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
}
