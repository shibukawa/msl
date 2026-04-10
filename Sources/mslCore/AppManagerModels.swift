import Foundation

public struct AppManagerWorkerRecord: Codable, Equatable {
    public var instanceName: String
    public var pid: Int32
    public var runtimeRoot: String
    public var controlSocketPath: String
    public var eventSocketPath: String
    public var lifecycleState: RuntimeLifecycleState
    public var startupStep: Int?
    public var startupStepName: String?
    public var lastErrorMessage: String?
    public var lastTransitionEpochMs: Int64

    public init(
        instanceName: String,
        pid: Int32,
        runtimeRoot: String,
        controlSocketPath: String,
        eventSocketPath: String,
        lifecycleState: RuntimeLifecycleState,
        startupStep: Int? = nil,
        startupStepName: String? = nil,
        lastErrorMessage: String? = nil,
        lastTransitionEpochMs: Int64
    ) {
        self.instanceName = instanceName
        self.pid = pid
        self.runtimeRoot = runtimeRoot
        self.controlSocketPath = controlSocketPath
        self.eventSocketPath = eventSocketPath
        self.lifecycleState = lifecycleState
        self.startupStep = startupStep
        self.startupStepName = startupStepName
        self.lastErrorMessage = lastErrorMessage
        self.lastTransitionEpochMs = lastTransitionEpochMs
    }
}

public struct AppManagerState: Codable, Equatable {
    public var schemaVersion: Int
    public var managerPID: Int32?
    public var managerSocketPath: String?
    public var managerStartedEpochMs: Int64?
    public var workers: [AppManagerWorkerRecord]
    public var lastUpdatedEpochMs: Int64

    public init(
        schemaVersion: Int = 1,
        managerPID: Int32? = nil,
        managerSocketPath: String? = nil,
        managerStartedEpochMs: Int64? = nil,
        workers: [AppManagerWorkerRecord] = [],
        lastUpdatedEpochMs: Int64
    ) {
        self.schemaVersion = schemaVersion
        self.managerPID = managerPID
        self.managerSocketPath = managerSocketPath
        self.managerStartedEpochMs = managerStartedEpochMs
        self.workers = workers.sorted { $0.instanceName < $1.instanceName }
        self.lastUpdatedEpochMs = lastUpdatedEpochMs
    }

    public static func initial(nowMs: Int64) -> AppManagerState {
        AppManagerState(lastUpdatedEpochMs: nowMs)
    }
}

