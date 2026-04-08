import Foundation
import Darwin

/// CLI → デーモン control socket クライアント。
/// デーモンが未起動なら自動的に起動して接続する。
public final class DaemonClient {
    private let paths: MSLPaths
    private let lock: FileLock
    private let store: StateStore
    private let logger: MSLLogger
    private let executablePath: String
    private let rpcLock = NSLock()
    private let processInfoProvider: () throws -> [DaemonProcessInfo]

    private var client: RuntimeControlClient?
    private var connectedInstanceName: String?

    public init(
        paths: MSLPaths,
        lock: FileLock,
        store: StateStore,
        logger: MSLLogger,
        executablePath: String
    ) {
        self.paths = paths
        self.lock = lock
        self.store = store
        self.logger = logger
        self.executablePath = executablePath
        self.processInfoProvider = { try Self.listDaemonProcesses() }
    }

    init(
        paths: MSLPaths,
        lock: FileLock,
        store: StateStore,
        logger: MSLLogger,
        executablePath: String,
        processInfoProvider: @escaping () throws -> [DaemonProcessInfo]
    ) {
        self.paths = paths
        self.lock = lock
        self.store = store
        self.logger = logger
        self.executablePath = executablePath
        self.processInfoProvider = processInfoProvider
    }

    deinit {
        disconnect()
    }

    /// Ensure daemon is running and establish a persistent connection.
    public func ensureConnected(
        expectedInstanceName: String? = nil,
        hostShareRoot: String? = nil,
        callerCwd: String? = nil
    ) throws {
        rpcLock.lock()
        defer { rpcLock.unlock() }
        try ensureConnectedLocked(
            expectedInstanceName: expectedInstanceName,
            hostShareRoot: hostShareRoot,
            callerCwd: callerCwd
        )
    }

    private func ensureConnectedLocked(
        expectedInstanceName: String? = nil,
        hostShareRoot: String? = nil,
        callerCwd: String? = nil
    ) throws {
        if client != nil {
            return
        }

        try cleanupStaleDaemonsIfNeeded(expectedInstanceName: expectedInstanceName)

        // Check if daemon is already running
        let initialState = try? lock.withExclusiveLock(timeoutSec: 2, { try store.loadState() })
        if let state = initialState,
           (state.daemonHostPid ?? state.runtimeHostPid) != nil {
            let daemonPid = state.daemonHostPid ?? state.runtimeHostPid ?? 0
            if isDaemonAlive(pid: daemonPid) {
                // Daemon is running, connect
                let socketPath = state.runtimeControlSocket ?? paths.runtimeControlSocketFile.path
                let c = RuntimeControlClient(socketPath: socketPath)
                do {
                    try c.connect()
                    self.client = c
                    self.connectedInstanceName = expectedInstanceName ?? state.distro
                    logger.log("daemon_client_connected_warm")
                    return
                } catch {
                    // Socket exists but connection failed — only treat stopped/error state as stale.
                    logger.log("daemon_client_stale_socket", fields: ["error": String(describing: error)])
                    if state.lifecycleState == .stopped || state.lifecycleState == .error {
                        try cleanupStaleDaemonState(
                            expectedInstanceName: expectedInstanceName,
                            additionalPIDs: daemonPid > 0 ? [daemonPid] : []
                        )
                    } else {
                        logger.log("daemon_client_existing_daemon_wait", fields: [
                            "pid": String(daemonPid),
                            "instance": expectedInstanceName ?? state.distro,
                            "lifecycle_state": state.lifecycleState.rawValue
                        ])
                        try waitForDaemonReady(
                            socketPath: socketPath,
                            daemonPID: daemonPid,
                            expectedInstanceName: expectedInstanceName ?? state.distro,
                            launchedAfterEpochMs: state.startupEpochMs ?? nowEpochMs(),
                            printReadyBanner: false
                        )
                        return
                    }
                }
            }
        }

        if let existingDaemon = existingDaemonProcess(expectedInstanceName: expectedInstanceName) {
            let instanceName = expectedInstanceName ?? initialState?.distro ?? existingDaemon.instanceName ?? "default"
            let socketPath = initialState?.runtimeControlSocket ?? paths.runtimeControlSocketFile.path
            logger.log("daemon_client_reusing_existing_daemon", fields: [
                "pid": String(existingDaemon.pid),
                "instance": instanceName,
                "socket_path": socketPath
            ])
            try waitForDaemonReady(
                socketPath: socketPath,
                daemonPID: existingDaemon.pid,
                expectedInstanceName: instanceName,
                launchedAfterEpochMs: initialState?.startupEpochMs ?? 0,
                printReadyBanner: false
            )
            return
        }

        // Daemon not running — start it
        fputs("msl: starting VM...\n", stderr)
        let launchStartMs = nowEpochMs()
        let launchedDaemonPID = try startDaemon(
            instanceName: expectedInstanceName,
            hostShareRoot: hostShareRoot,
            callerCwd: callerCwd
        )

        try waitForDaemonReady(
            socketPath: paths.runtimeControlSocketFile.path,
            daemonPID: launchedDaemonPID,
            expectedInstanceName: expectedInstanceName,
            launchedAfterEpochMs: launchStartMs,
            printReadyBanner: true
        )
    }

    /// Send a request to the daemon. Auto-connects if needed.
    public func send(_ request: RuntimeControlRequest) throws -> RuntimeControlResponse {
        rpcLock.lock()
        defer { rpcLock.unlock() }
        try ensureConnectedLocked()
        guard let c = client else {
            throw MSLRuntimeError("not connected to daemon")
        }
        return try c.sendPersistent(request)
    }

    public func sendNoReply(_ request: RuntimeControlRequest) throws {
        rpcLock.lock()
        defer { rpcLock.unlock() }
        try ensureConnectedLocked()
        let socketPath = paths.runtimeControlSocketFile.path
        let c = RuntimeControlClient(socketPath: socketPath)
        try c.connect()
        defer { c.disconnect() }
        try c.sendPersistentNoReply(request)
    }

    /// Send a single-shot request (new connection per request).
    /// Use for one-off operations like --status or --stop.
    public func sendOneShot(_ request: RuntimeControlRequest) throws -> RuntimeControlResponse {
        rpcLock.lock()
        defer { rpcLock.unlock() }
        try ensureConnectedLocked()
        let socketPath = paths.runtimeControlSocketFile.path
        let c = RuntimeControlClient(socketPath: socketPath)
        return try c.send(request)
    }

    /// Send a single-shot request on an independent connection without
    /// serializing against the primary persistent RPC lock. This is used for
    /// attached exec stdin so proc_write can progress in parallel with
    /// proc_read on the main control connection.
    public func sendIndependentOneShot(_ request: RuntimeControlRequest) throws -> RuntimeControlResponse {
        let socketPath: String
        rpcLock.lock()
        do {
            try ensureConnectedLocked()
            socketPath = paths.runtimeControlSocketFile.path
        } catch {
            rpcLock.unlock()
            throw error
        }
        rpcLock.unlock()

        let c = RuntimeControlClient(socketPath: socketPath)
        return try c.send(request)
    }

    func makeIndependentPersistentClient() throws -> RuntimeControlClient {
        let socketPath: String
        rpcLock.lock()
        do {
            try ensureConnectedLocked()
            socketPath = paths.runtimeControlSocketFile.path
        } catch {
            rpcLock.unlock()
            throw error
        }
        rpcLock.unlock()

        let c = RuntimeControlClient(socketPath: socketPath)
        try c.connect()
        return c
    }

    public func procSubscribe(procId: String) throws -> RuntimeControlProcEventStream {
        let socketPath: String
        rpcLock.lock()
        do {
            try ensureConnectedLocked()
            socketPath = paths.runtimeControlSocketFile.path
        } catch {
            rpcLock.unlock()
            throw error
        }
        rpcLock.unlock()
        let c = RuntimeControlClient(socketPath: socketPath)
        return try c.procSubscribe(procId: procId)
    }

    public func ptySubscribe(ptyId: String) throws -> RuntimeControlPtyEventStream {
        let socketPath: String
        rpcLock.lock()
        do {
            try ensureConnectedLocked()
            socketPath = paths.runtimeControlSocketFile.path
        } catch {
            rpcLock.unlock()
            throw error
        }
        rpcLock.unlock()
        let c = RuntimeControlClient(socketPath: socketPath)
        return try c.ptySubscribe(ptyId: ptyId)
    }

    /// Disconnect from the daemon.
    public func disconnect() {
        rpcLock.lock()
        defer { rpcLock.unlock() }
        client?.disconnect()
        client = nil
        connectedInstanceName = nil
    }

    // MARK: - Daemon Startup

    @discardableResult
    private func startDaemon(instanceName: String?, hostShareRoot: String?, callerCwd: String?) throws -> Int32 {
        logger.log("daemon_client_starting_daemon")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        var arguments = ["--_daemon"]
        if let instanceName, !instanceName.isEmpty {
            arguments.append("--instance")
            arguments.append(instanceName)
        }
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        var hasEnvironmentOverride = false
        if let hostShareRoot = hostShareRoot?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hostShareRoot.isEmpty {
            environment["MSL_HOST_SHARE_ROOT"] = hostShareRoot
            hasEnvironmentOverride = true
        }
        if let callerCwd = callerCwd?.trimmingCharacters(in: .whitespacesAndNewlines),
           !callerCwd.isEmpty {
            environment["MSL_DAEMON_LAUNCH_CWD"] = callerCwd
            hasEnvironmentOverride = true
        }
        if hasEnvironmentOverride {
            process.environment = environment
        }

        // Redirect daemon output to log, detach from terminal
        let logURL = paths.logs.appendingPathComponent("daemon.log", isDirectory: false)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        process.standardOutput = try FileHandle(forWritingTo: logURL)
        process.standardError = try FileHandle(forWritingTo: logURL)
        process.standardInput = FileHandle.nullDevice

        try process.run()
        // Don't wait — daemon is long-running

        logger.log("daemon_client_daemon_launched", fields: [
            "pid": String(process.processIdentifier),
            "instance": instanceName ?? ""
        ])
        return process.processIdentifier
    }

    private func isDaemonAlive(pid: Int32) -> Bool {
        if pid <= 0 { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    private func resolveStartupTimeoutSec() -> Int {
        return 30
    }

    private func waitForDaemonReady(
        socketPath: String,
        daemonPID: Int32,
        expectedInstanceName: String?,
        launchedAfterEpochMs: Int64,
        printReadyBanner: Bool
    ) throws {
        let maxWaitSec = resolveStartupTimeoutSec()
        let deadline = Date().addingTimeInterval(TimeInterval(maxWaitSec))
        var waitCount = 0

        while Date() < deadline {
            if isInterrupted() {
                throw MSLRuntimeError("interrupted by user")
            }
            let socketExists = FileManager.default.fileExists(atPath: socketPath)
            if waitCount < 5 || waitCount % 25 == 0 {
                logger.log("daemon_client_cold_connect_poll", fields: [
                    "socket_exists": socketExists ? "true" : "false",
                    "wait_count": String(waitCount),
                    "socket_path": socketPath,
                    "daemon_pid": String(daemonPID)
                ])
            }
            if socketExists {
                let c = RuntimeControlClient(socketPath: socketPath)
                do {
                    logger.log("daemon_client_cold_connect_attempt", fields: [
                        "wait_count": String(waitCount),
                        "daemon_pid": String(daemonPID)
                    ])
                    try c.connect()
                    self.client = c
                    self.connectedInstanceName = expectedInstanceName
                    if printReadyBanner {
                        fputs("msl: VM ready\n", stderr)
                    }
                    logger.log("daemon_client_connected_cold")
                    return
                } catch {
                    logger.log("daemon_client_cold_connect_retry", fields: [
                        "wait_count": String(waitCount),
                        "error": String(describing: error),
                        "daemon_pid": String(daemonPID)
                    ])
                }
            }
            if let startupFailure = detectStartupStateFailure(
                expectedInstanceName: expectedInstanceName,
                launchedAfterEpochMs: launchedAfterEpochMs
            ) {
                throw MSLRuntimeError(startupFailure)
            }
            if !isDaemonAlive(pid: daemonPID) {
                throw MSLRuntimeError("VM start failed: daemon exited before control socket became ready")
            }
            waitCount += 1
            if waitCount % 25 == 0 {
                let stepText = currentStartupStepDescription(expectedInstanceName: expectedInstanceName)
                fputs("msl: waiting for VM to start...\(stepText)\n", stderr)
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        throw MSLRuntimeError("daemon did not start within \(maxWaitSec)s")
    }

    func detectStartupStateFailure(expectedInstanceName: String?, launchedAfterEpochMs: Int64 = 0) -> String? {
        guard let state = try? lock.withExclusiveLock(timeoutSec: 1, { try store.loadState() }) else {
            return nil
        }
        let instanceName = expectedInstanceName ?? state.distro
        if let entry = state.instances?.first(where: { $0.instance == instanceName }),
           entry.lastTransitionEpochMs >= launchedAfterEpochMs,
           entry.lifecycleState == .error,
           let message = entry.lastErrorMessage ?? entry.lastError,
           !message.isEmpty {
            let stepNumber = entry.startupStep.map(String.init) ?? "?"
            let stepName = entry.startupStepName ?? "unknown"
            return "VM start failed: step \(stepNumber): \(stepName): \(message)"
        }
        return nil
    }

    private func currentStartupStepDescription(expectedInstanceName: String?) -> String {
        guard let state = try? lock.withExclusiveLock(timeoutSec: 1, { try store.loadState() }) else {
            return ""
        }
        let instanceName = expectedInstanceName ?? state.distro
        guard let entry = state.instances?.first(where: { $0.instance == instanceName }),
              entry.lifecycleState == .starting,
              let step = entry.startupStep,
              let name = entry.startupStepName else {
            return ""
        }
        return " (step \(step): \(name))"
    }

    private func cleanupStaleDaemonsIfNeeded(expectedInstanceName: String?) throws {
        let state = (try? lock.withExclusiveLock(timeoutSec: 1, { try store.loadState() })) ?? .initial(nowMs: nowEpochMs())
        let candidates = detectStaleDaemonCandidates(state: state, expectedInstanceName: expectedInstanceName)
        guard !candidates.isEmpty else {
            return
        }
        try cleanupStaleDaemonState(
            expectedInstanceName: expectedInstanceName,
            additionalPIDs: candidates.map(\.pid)
        )
    }

    private func cleanupStaleDaemonState(expectedInstanceName: String?, additionalPIDs: [Int32]) throws {
        let uniquePIDs = Array(Set(additionalPIDs.filter { $0 > 0 }))
        if !uniquePIDs.isEmpty {
            for pid in uniquePIDs {
                _ = kill(pid, SIGTERM)
            }
            let deadline = Date().addingTimeInterval(2.0)
            while Date() < deadline {
                if uniquePIDs.allSatisfy({ !isDaemonAlive(pid: $0) }) {
                    break
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            for pid in uniquePIDs where isDaemonAlive(pid: pid) {
                _ = kill(pid, SIGKILL)
            }
            if uniquePIDs.contains(where: { isDaemonAlive(pid: $0) }) {
                throw MSLRuntimeError("stale daemon detected and cleanup failed")
            }
        }

        try sessionsCleanupAndStateNormalize(expectedInstanceName: expectedInstanceName)
        removeRuntimeSocketIfPresent(paths.runtimeControlSocketFile.path)
        removeRuntimeSocketIfPresent(paths.runtimeEventSocketFile.path)
        logger.log("daemon_client_stale_daemon_cleaned", fields: [
            "instance": expectedInstanceName ?? "",
            "pid_count": String(uniquePIDs.count)
        ])
    }

    private func sessionsCleanupAndStateNormalize(expectedInstanceName: String?) throws {
        let sessions = SessionManager(store: store)
        try sessions.clearAllAndTerminate()
        try lock.withExclusiveLock(timeoutSec: 2) {
            var state = try store.loadState()
            _ = DaemonStartupStateNormalizer.normalizeForDaemonStart(state: &state, nowMs: nowEpochMs())
            let instanceName = expectedInstanceName ?? state.distro
            if state.instances?.contains(where: { $0.instance == instanceName }) == true,
               let idx = state.instances?.firstIndex(where: { $0.instance == instanceName }) {
                state.instances?[idx].lastError = nil
            }
            state.vmState = .stopped
            state.activeSessionCount = 0
            state.idleTimer = IdleTimerState(armed: false, deadlineEpochMs: nil)
            state.runtimeHostPid = nil
            state.runtimeControlSocket = nil
            state.daemonHostPid = nil
            state.daemonControlSocket = nil
            state.daemonEventSocket = nil
            try store.saveState(state)
        }
    }

    private func removeRuntimeSocketIfPresent(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            return
        }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            logger.log("daemon_client_stale_socket_remove_failed", fields: [
                "path": path,
                "error": String(describing: error)
            ])
        }
    }

    func detectStaleDaemonCandidates(state: RuntimeState, expectedInstanceName: String?) -> [DaemonProcessInfo] {
        let controlSocketPath = state.runtimeControlSocket ?? paths.runtimeControlSocketFile.path
        let eventSocketPath = state.daemonEventSocket ?? paths.runtimeEventSocketFile.path
        let hasControlSocket = FileManager.default.fileExists(atPath: controlSocketPath)
        let hasEventSocket = FileManager.default.fileExists(atPath: eventSocketPath)
        let trackedPID = state.daemonHostPid ?? state.runtimeHostPid
        let hasNoRuntimeSockets = !hasControlSocket && !hasEventSocket
        let brokenRunningState = state.lifecycleState == .running && hasNoRuntimeSockets
        let canTreatLiveDaemonAsStale = state.lifecycleState == .stopped || state.lifecycleState == .error || brokenRunningState
        let trackedPidIsStale = trackedPID.map {
            isDaemonAlive(pid: $0) && state.vmState == .stopped && canTreatLiveDaemonAsStale
        } ?? false
        let trackedRunningPidIsStale = trackedPID.map {
            isDaemonAlive(pid: $0) && brokenRunningState
        } ?? false

        let processes = (try? processInfoProvider()) ?? []
        let relevantProcesses = processes.filter { process in
            guard process.isDaemon else { return false }
            if let expectedInstanceName, !expectedInstanceName.isEmpty {
                return process.instanceName == expectedInstanceName
            }
            return true
        }

        let orphanedLiveDaemons = hasNoRuntimeSockets && !relevantProcesses.isEmpty && canTreatLiveDaemonAsStale
        guard trackedPidIsStale || trackedRunningPidIsStale || orphanedLiveDaemons else {
            return []
        }

        var candidates = relevantProcesses.filter { process in
            if let trackedPID {
                return process.pid == trackedPID || hasNoRuntimeSockets
            }
            return hasNoRuntimeSockets
        }
        if (trackedPidIsStale || trackedRunningPidIsStale),
           let trackedPID,
           !candidates.contains(where: { $0.pid == trackedPID }) {
            candidates.append(DaemonProcessInfo(pid: trackedPID, command: "", instanceName: expectedInstanceName ?? state.distro))
        }
        return candidates
    }

    private func existingDaemonProcess(expectedInstanceName: String?) -> DaemonProcessInfo? {
        let processes = (try? processInfoProvider()) ?? []
        return processes.first { process in
            guard process.isDaemon else { return false }
            guard isDaemonAlive(pid: process.pid) else { return false }
            if let expectedInstanceName, !expectedInstanceName.isEmpty {
                return process.instanceName == expectedInstanceName
            }
            return true
        }
    }

    static func listDaemonProcesses() throws -> [DaemonProcessInfo] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Ao", "pid=,command="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return parseDaemonProcessList(text)
    }

    static func parseDaemonProcessList(_ text: String) -> [DaemonProcessInfo] {
        text.split(separator: "\n").compactMap { rawLine in
            let line = String(rawLine)
            let pattern = #"^\s*(\d+)\s+(.+)$"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                return nil
            }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let pidRange = Range(match.range(at: 1), in: line),
                  let commandRange = Range(match.range(at: 2), in: line),
                  let pid = Int32(String(line[pidRange])) else {
                return nil
            }
            let command = String(line[commandRange])
            guard command.contains("msl --_daemon") else {
                return nil
            }
            let instanceName = command.components(separatedBy: " --instance ").dropFirst().first?.split(separator: " ").first.map(String.init)
            return DaemonProcessInfo(pid: pid, command: command, instanceName: instanceName)
        }
    }
}

struct DaemonProcessInfo: Equatable {
    var pid: Int32
    var command: String
    var instanceName: String?

    var isDaemon: Bool {
        command.contains("msl --_daemon")
    }
}
