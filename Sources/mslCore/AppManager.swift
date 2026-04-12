import Foundation
import Darwin

public final class AppManager {
    private let paths: MSLPaths
    private let fileManager: FileManager
    private let logger: MSLLogger
    private let stateStore: AppManagerStateStore
    private let executablePath: String
    private let stateLock = NSLock()
    private let workerProcessLock = NSLock()
    private let shutdownLock = NSLock()

    private var server: ManagerControlServer?
    private var workerProcesses: [String: Process] = [:]
    private var showWindowHandler: (() -> Void)?
    private var shuttingDown = false

    public init(
        paths: MSLPaths,
        fileManager: FileManager = .default,
        logger: MSLLogger,
        executablePath: String
    ) {
        self.paths = paths
        self.fileManager = fileManager
        self.logger = logger
        self.stateStore = AppManagerStateStore(paths: paths, fileManager: fileManager)
        self.executablePath = executablePath
    }

    public func setShowWindowHandler(_ handler: @escaping () -> Void) {
        showWindowHandler = handler
    }

    public func start() throws {
        try fileManager.createDirectory(at: paths.appControl, withIntermediateDirectories: true)
        _ = try? stateStore.reconcile(pingManager: { [paths] in
            guard let socketPath = try? AppManager.pingManagerSocket(paths.managerSocketFile.path) else {
                return false
            }
            return socketPath
        })
        let server = ManagerControlServer(socketPath: paths.managerSocketFile.path) { [weak self] request in
            self?.handle(request) ?? ManagerControlResponse(ok: false, error: "manager unavailable")
        }
        try server.start()
        self.server = server

        try updateState { state in
            state.managerPID = Int32(getpid())
            state.managerSocketPath = self.paths.managerSocketFile.path
            state.managerStartedEpochMs = nowEpochMs()
            state.lastUpdatedEpochMs = nowEpochMs()
        }
        shutdownLock.lock()
        shuttingDown = false
        shutdownLock.unlock()
    }

    public func stop() {
        shutdownLock.lock()
        shuttingDown = true
        shutdownLock.unlock()

        let trackedWorkers = snapshot().workers
        for worker in trackedWorkers {
            _ = try? stopWorker(instanceName: worker.instanceName, tolerateUnavailableSocket: true)
        }

        let gracefulDeadline = Date().addingTimeInterval(3.0)
        while Date() < gracefulDeadline {
            let liveWorkers = snapshot().workers.filter { isProcessAlive($0.pid) }
            if liveWorkers.isEmpty {
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        workerProcessLock.lock()
        let activeProcesses = workerProcesses
        workerProcesses.removeAll()
        workerProcessLock.unlock()
        for process in activeProcesses.values where process.isRunning {
            process.terminate()
        }

        let forceDeadline = Date().addingTimeInterval(1.0)
        while Date() < forceDeadline {
            if activeProcesses.values.allSatisfy({ !$0.isRunning }) {
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        for process in activeProcesses.values where process.isRunning {
            process.interrupt()
        }

        server?.stop()
        server = nil

        try? updateState { state in
            state.managerPID = nil
            state.managerSocketPath = nil
            state.managerStartedEpochMs = nil
            state.workers.removeAll()
            state.lastUpdatedEpochMs = nowEpochMs()
        }
    }

    public func snapshot() -> AppManagerState {
        (try? stateStore.load()) ?? .initial(nowMs: nowEpochMs())
    }

    private func handle(_ request: ManagerControlRequest) -> ManagerControlResponse {
        shutdownLock.lock()
        let isShuttingDown = shuttingDown
        shutdownLock.unlock()
        if isShuttingDown,
           request.op != "worker_unregister" {
            return ManagerControlResponse(ok: false, error: "manager shutting down")
        }
        do {
            switch request.op {
            case "app_ping":
                return ManagerControlResponse(ok: true, workers: snapshot().workers)
            case "list_instances":
                return ManagerControlResponse(ok: true, workers: snapshot().workers)
            case "show_window":
                DispatchQueue.main.async { [showWindowHandler] in
                    showWindowHandler?()
                }
                return ManagerControlResponse(ok: true, workers: snapshot().workers)
            case "ensure_instance":
                guard let instance = request.instance?.trimmingCharacters(in: .whitespacesAndNewlines), !instance.isEmpty else {
                    return ManagerControlResponse(ok: false, error: "missing instance")
                }
                let worker = try ensureWorker(
                    instanceName: instance,
                    callerCwd: request.callerCwd,
                    hostShareRoot: request.hostShareRoot
                )
                return ManagerControlResponse(ok: true, worker: worker)
            case "ssh_info":
                guard let instance = request.instance?.trimmingCharacters(in: .whitespacesAndNewlines), !instance.isEmpty else {
                    return ManagerControlResponse(ok: false, error: "missing instance")
                }
                let worker = try ensureWorker(
                    instanceName: instance,
                    callerCwd: request.callerCwd,
                    hostShareRoot: request.hostShareRoot
                )
                guard let sshInfo = worker.sshInfo else {
                    return ManagerControlResponse(ok: false, error: "ssh listener is not ready for instance '\(instance)'")
                }
                return ManagerControlResponse(ok: true, sshInfo: sshInfo, worker: worker)
            case "stop_instance":
                guard let instance = request.instance?.trimmingCharacters(in: .whitespacesAndNewlines), !instance.isEmpty else {
                    return ManagerControlResponse(ok: false, error: "missing instance")
                }
                try stopWorker(instanceName: instance)
                return ManagerControlResponse(ok: true, worker: snapshot().workers.first(where: { $0.instanceName == instance }))
            case "stop_manager":
                DispatchQueue.global().async { [weak self] in
                    self?.stop()
                }
                return ManagerControlResponse(ok: true)
            case "worker_register":
                guard
                    let instance = request.instance,
                    let pid = request.pid,
                    let runtimeRoot = request.runtimeRoot,
                    let controlSocketPath = request.controlSocketPath,
                    let eventSocketPath = request.eventSocketPath,
                    let lifecycleState = request.lifecycleState
                else {
                    return ManagerControlResponse(ok: false, error: "incomplete worker registration")
                }
                let record = AppManagerWorkerRecord(
                    instanceName: instance,
                    pid: pid,
                    runtimeRoot: runtimeRoot,
                    controlSocketPath: controlSocketPath,
                    eventSocketPath: eventSocketPath,
                    sshInfo: request.sshInfo,
                    sshListenerState: request.sshListenerState,
                    sshLastErrorMessage: request.sshLastErrorMessage,
                    lifecycleState: lifecycleState,
                    startupStep: request.startupStep,
                    startupStepName: request.startupStepName,
                    lastErrorMessage: request.lastErrorMessage,
                    lastTransitionEpochMs: nowEpochMs()
                )
                try upsertWorker(record)
                return ManagerControlResponse(ok: true, worker: record)
            case "worker_unregister":
                guard let instance = request.instance else {
                    return ManagerControlResponse(ok: false, error: "missing instance")
                }
                try removeWorker(instanceName: instance)
                return ManagerControlResponse(ok: true)
            default:
                return ManagerControlResponse(ok: false, error: "unsupported manager op: \(request.op)")
            }
        } catch let error as MSLRuntimeError {
            return ManagerControlResponse(ok: false, error: error.message)
        } catch {
            return ManagerControlResponse(ok: false, error: String(describing: error))
        }
    }

    private func ensureWorker(instanceName: String, callerCwd: String?, hostShareRoot: String?) throws -> AppManagerWorkerRecord {
        if let existing = try? resolveRunningWorker(instanceName: instanceName) {
            return existing
        }

        let runtimeRoot = paths.workerRuntimeDirectory(named: instanceName)
        try fileManager.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: runtimeRoot.appendingPathComponent("logs", isDirectory: true), withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["--_worker", "--instance", instanceName]
        var environment = ProcessInfo.processInfo.environment
        environment["MSL_RUNTIME_ROOT"] = runtimeRoot.path
        environment["MSL_MANAGER_SOCKET"] = paths.managerSocketFile.path
        if let callerCwd, !callerCwd.isEmpty {
            environment["MSL_DAEMON_LAUNCH_CWD"] = callerCwd
        }
        if let hostShareRoot, !hostShareRoot.isEmpty {
            environment["MSL_HOST_SHARE_ROOT"] = hostShareRoot
        }
        process.environment = environment

        let logURL = runtimeRoot.appendingPathComponent("manager-worker.log", isDirectory: false)
        fileManager.createFile(atPath: logURL.path, contents: nil)
        process.standardOutput = try FileHandle(forWritingTo: logURL)
        process.standardError = try FileHandle(forWritingTo: logURL)
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] proc in
            self?.handleWorkerExit(instanceName: instanceName, process: proc)
        }
        try process.run()

        workerProcessLock.lock()
        workerProcesses[instanceName] = process
        workerProcessLock.unlock()

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let worker = try? resolveRunningWorker(instanceName: instanceName) {
                return worker
            }
            if !process.isRunning && process.terminationStatus != 0 {
                throw MSLRuntimeError("worker failed to start for instance '\(instanceName)'")
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        throw MSLRuntimeError("worker did not register in time for instance '\(instanceName)'")
    }

    private func resolveRunningWorker(instanceName: String) throws -> AppManagerWorkerRecord {
        let state = try stateStore.load()
        guard let record = state.workers.first(where: { $0.instanceName == instanceName }) else {
            throw MSLRuntimeError("worker not registered")
        }
        guard kill(record.pid, 0) == 0 || errno == EPERM else {
            throw MSLRuntimeError("worker process is not alive")
        }
        guard fileManager.fileExists(atPath: record.controlSocketPath) else {
            throw MSLRuntimeError("worker control socket is not ready")
        }
        return record
    }

    @discardableResult
    private func stopWorker(instanceName: String, tolerateUnavailableSocket: Bool = false) throws -> Bool {
        guard let record = snapshot().workers.first(where: { $0.instanceName == instanceName }) else {
            return false
        }
        let client = RuntimeControlClient(socketPath: record.controlSocketPath)
        let response: RuntimeControlResponse
        do {
            response = try client.send(RuntimeControlRequest(op: "instance_stop", instance: instanceName, all: false))
        } catch {
            if tolerateUnavailableSocket, Self.isManagerOrWorkerUnavailable(error) {
                try removeWorker(instanceName: instanceName)
                return false
            }
            throw error
        }
        guard response.ok else {
            throw MSLRuntimeError(response.error ?? "failed to stop instance")
        }
        return true
    }

    private func handleWorkerExit(instanceName: String, process: Process) {
        workerProcessLock.lock()
        workerProcesses.removeValue(forKey: instanceName)
        workerProcessLock.unlock()
        try? updateState { state in
            state.workers.removeAll { $0.instanceName == instanceName }
            state.lastUpdatedEpochMs = nowEpochMs()
        }
    }

    private func upsertWorker(_ worker: AppManagerWorkerRecord) throws {
        try updateState { state in
            state.workers.removeAll { $0.instanceName == worker.instanceName }
            state.workers.append(worker)
            state.workers.sort { $0.instanceName < $1.instanceName }
            state.lastUpdatedEpochMs = nowEpochMs()
        }
    }

    private func removeWorker(instanceName: String) throws {
        try updateState { state in
            state.workers.removeAll { $0.instanceName == instanceName }
            state.lastUpdatedEpochMs = nowEpochMs()
        }
    }

    private func updateState(_ mutate: (inout AppManagerState) throws -> Void) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        var state = try stateStore.load()
        try mutate(&state)
        try stateStore.save(state)
    }

    private func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    private static func pingManagerSocket(_ socketPath: String) throws -> Bool {
        let client = ManagerControlClient(socketPath: socketPath)
        let response = try client.send(ManagerControlRequest(op: "app_ping"))
        return response.ok
    }

    private static func isManagerOrWorkerUnavailable(_ error: Error) -> Bool {
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
            || description.contains("socket is not connected")
            || description.contains("not a socket")
    }
}
