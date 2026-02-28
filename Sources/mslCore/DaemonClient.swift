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
    }

    deinit {
        disconnect()
    }

    /// Ensure daemon is running and establish a persistent connection.
    public func ensureConnected(expectedInstanceName: String? = nil, hostShareRoot: String? = nil) throws {
        if client != nil {
            if let expectedInstanceName,
               let connectedInstanceName,
               connectedInstanceName != expectedInstanceName {
                throw MSLRuntimeError(
                    "daemon is connected to instance '\(connectedInstanceName)'. run `msl --stop` before switching to '\(expectedInstanceName)'."
                )
            }
            return
        }

        // Check if daemon is already running
        if let state = try? lock.withExclusiveLock(timeoutSec: 2, { try store.loadState() }),
           state.vmState == .running,
           let pid = state.runtimeHostPid, isDaemonAlive(pid: pid) {
            if let expectedInstanceName,
               state.distro != expectedInstanceName {
                throw MSLRuntimeError(
                    "daemon is running instance '\(state.distro)'. run `msl --stop` before switching to '\(expectedInstanceName)'."
                )
            }
            // Daemon is running, connect
            let socketPath = state.runtimeControlSocket ?? paths.runtimeControlSocketFile.path
            let c = RuntimeControlClient(socketPath: socketPath)
            do {
                try c.connect()
                self.client = c
                self.connectedInstanceName = state.distro
                logger.log("daemon_client_connected_warm")
                return
            } catch {
                // Socket exists but connection failed — stale state; restart daemon
                logger.log("daemon_client_stale_socket", fields: ["error": String(describing: error)])
            }
        }

        // Daemon not running — start it
        fputs("msl: starting VM...\n", stderr)
        try startDaemon(instanceName: expectedInstanceName, hostShareRoot: hostShareRoot)

        // Wait for control socket to appear and connect
        let socketPath = paths.runtimeControlSocketFile.path
        let daemonLogPath = paths.logs.appendingPathComponent("daemon.log", isDirectory: false).path
        let maxWaitSec = resolveStartupTimeoutSec()
        let deadline = Date().addingTimeInterval(TimeInterval(maxWaitSec))
        var waitCount = 0

        while Date() < deadline {
            if isInterrupted() {
                throw MSLRuntimeError("interrupted by user")
            }
            if FileManager.default.fileExists(atPath: socketPath) {
                let c = RuntimeControlClient(socketPath: socketPath)
                do {
                    try c.connect()
                    self.client = c
                    self.connectedInstanceName = expectedInstanceName
                    fputs("msl: VM ready\n", stderr)
                    logger.log("daemon_client_connected_cold")
                    return
                } catch {
                    // Socket file exists but not ready yet
                }
            }
            if let startupFailure = detectDaemonStartupFailure(logPath: daemonLogPath) {
                throw MSLRuntimeError(startupFailure)
            }
            waitCount += 1
            if waitCount % 25 == 0 {  // every ~5 seconds
                fputs("msl: waiting for VM to start...\n", stderr)
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        throw MSLRuntimeError("daemon did not start within \(maxWaitSec)s")
    }

    /// Send a request to the daemon. Auto-connects if needed.
    public func send(_ request: RuntimeControlRequest) throws -> RuntimeControlResponse {
        try ensureConnected()
        guard let c = client else {
            throw MSLRuntimeError("not connected to daemon")
        }
        return try c.sendPersistent(request)
    }

    /// Send a single-shot request (new connection per request).
    /// Use for one-off operations like --status or --stop.
    public func sendOneShot(_ request: RuntimeControlRequest) throws -> RuntimeControlResponse {
        try ensureConnected()
        let socketPath = paths.runtimeControlSocketFile.path
        let c = RuntimeControlClient(socketPath: socketPath)
        return try c.send(request)
    }

    /// Disconnect from the daemon.
    public func disconnect() {
        client?.disconnect()
        client = nil
        connectedInstanceName = nil
    }

    // MARK: - Daemon Startup

    private func startDaemon(instanceName: String?, hostShareRoot: String?) throws {
        logger.log("daemon_client_starting_daemon")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        var arguments = ["--_daemon"]
        if let instanceName, !instanceName.isEmpty {
            arguments.append("--instance")
            arguments.append(instanceName)
        }
        process.arguments = arguments
        if let hostShareRoot = hostShareRoot?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hostShareRoot.isEmpty {
            var environment = ProcessInfo.processInfo.environment
            environment["MSL_HOST_SHARE_ROOT"] = hostShareRoot
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
    }

    private func isDaemonAlive(pid: Int32) -> Bool {
        if pid <= 0 { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    private func resolveStartupTimeoutSec() -> Int {
        return 30
    }

    private func detectDaemonStartupFailure(logPath: String) -> String? {
        guard let data = FileManager.default.contents(atPath: logPath),
              !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        if text.contains("com.apple.security.virtualization") &&
            text.contains("daemon_vm_start_failed") {
            return "VM start failed: missing com.apple.security.virtualization entitlement. run ./scripts/build-signed.sh and retry."
        }
        return nil
    }
}
