import Foundation

public struct AppManagerStateReconciliationResult {
    public var previousState: AppManagerState
    public var state: AppManagerState
    public var removedWorkerInstances: [String]
    public var managerWasCleared: Bool

    public var hadTrackedWorkers: Bool {
        !previousState.workers.isEmpty
    }

    public func trackedWorker(instanceName: String) -> Bool {
        previousState.workers.contains { $0.instanceName == instanceName }
    }
}

public final class AppManagerStateStore {
    private let paths: MSLPaths
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(paths: MSLPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func load() throws -> AppManagerState {
        if !fileManager.fileExists(atPath: paths.managerStateFile.path) {
            return .initial(nowMs: nowEpochMs())
        }
        return try decoder.decode(AppManagerState.self, from: Data(contentsOf: paths.managerStateFile))
    }

    public func save(_ state: AppManagerState) throws {
        try fileManager.createDirectory(at: paths.appControl, withIntermediateDirectories: true)
        let data = try encoder.encode(state)
        try data.write(to: paths.managerStateFile, options: .atomic)
    }

    public func reconcile(
        pingManager: (() -> Bool)? = nil,
        preservingManagerPID: Int32? = nil
    ) throws -> AppManagerStateReconciliationResult {
        let previous = try load()
        var state = previous
        let removedWorkers = previous.workers.compactMap { worker -> String? in
            guard shouldKeepWorker(worker) else { return worker.instanceName }
            return nil
        }
        if !removedWorkers.isEmpty {
            state.workers.removeAll { worker in
                removedWorkers.contains(worker.instanceName)
            }
        }

        var managerWasCleared = false
        if shouldClearManager(state, pingManager: pingManager, preservingManagerPID: preservingManagerPID) {
            managerWasCleared = state.managerPID != nil
                || state.managerSocketPath != nil
                || state.managerStartedEpochMs != nil
            state.managerPID = nil
            state.managerSocketPath = nil
            state.managerStartedEpochMs = nil
        }

        if !removedWorkers.isEmpty || managerWasCleared {
            state.lastUpdatedEpochMs = nowEpochMs()
            try save(state)
        }

        return AppManagerStateReconciliationResult(
            previousState: previous,
            state: state,
            removedWorkerInstances: removedWorkers,
            managerWasCleared: managerWasCleared
        )
    }

    private func shouldKeepWorker(_ worker: AppManagerWorkerRecord) -> Bool {
        isProcessAlive(worker.pid)
            && fileManager.fileExists(atPath: worker.controlSocketPath)
    }

    private func shouldClearManager(
        _ state: AppManagerState,
        pingManager: (() -> Bool)?,
        preservingManagerPID: Int32?
    ) -> Bool {
        guard let managerPID = state.managerPID else {
            return false
        }
        if let preservingManagerPID, preservingManagerPID == managerPID {
            return false
        }
        guard isProcessAlive(managerPID),
              let socketPath = state.managerSocketPath,
              !socketPath.isEmpty,
              fileManager.fileExists(atPath: socketPath) else {
            return true
        }
        if let pingManager, !pingManager() {
            return true
        }
        return false
    }

    private func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
