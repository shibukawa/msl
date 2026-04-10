import XCTest
@testable import mslCore

final class AppManagerStateStoreTests: XCTestCase {
    func testAppManagerStateRoundTrip() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-app-manager-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = MSLPaths(homeDirectoryURL: root)
        let store = AppManagerStateStore(paths: paths, fileManager: .default)
        let state = AppManagerState(
            managerPID: 123,
            managerSocketPath: paths.managerSocketFile.path,
            managerStartedEpochMs: 456,
            workers: [
                AppManagerWorkerRecord(
                    instanceName: "ubuntu",
                    pid: 999,
                    runtimeRoot: paths.workerRuntimeDirectory(named: "ubuntu").path,
                    controlSocketPath: paths.workerControlSocketFile(named: "ubuntu").path,
                    eventSocketPath: paths.workerEventSocketFile(named: "ubuntu").path,
                    lifecycleState: .running,
                    startupStep: 5,
                    startupStepName: "control_socket_start",
                    lastErrorMessage: nil,
                    lastTransitionEpochMs: 789
                )
            ],
            lastUpdatedEpochMs: 789
        )

        try store.save(state)
        let loaded = try store.load()

        XCTAssertEqual(loaded.managerPID, 123)
        XCTAssertEqual(loaded.workers.first?.instanceName, "ubuntu")
        XCTAssertEqual(loaded.workers.first?.controlSocketPath, paths.workerControlSocketFile(named: "ubuntu").path)
    }

    func testReconcileRemovesDeadWorkersAndClearsDeadManager() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-app-manager-reconcile-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = MSLPaths(homeDirectoryURL: root)
        try FileManager.default.createDirectory(at: paths.appControl, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.managerSocketFile.path, contents: Data())

        let staleWorkerSocket = paths.workerControlSocketFile(named: "ubuntu")
        try FileManager.default.createDirectory(at: staleWorkerSocket.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: staleWorkerSocket.path, contents: Data())

        let store = AppManagerStateStore(paths: paths, fileManager: .default)
        try store.save(
            AppManagerState(
                managerPID: 999_999,
                managerSocketPath: paths.managerSocketFile.path,
                managerStartedEpochMs: 100,
                workers: [
                    AppManagerWorkerRecord(
                        instanceName: "ubuntu",
                        pid: 999_998,
                        runtimeRoot: paths.workerRuntimeDirectory(named: "ubuntu").path,
                        controlSocketPath: staleWorkerSocket.path,
                        eventSocketPath: paths.workerEventSocketFile(named: "ubuntu").path,
                        lifecycleState: .running,
                        lastTransitionEpochMs: 123
                    )
                ],
                lastUpdatedEpochMs: 123
            )
        )

        let result = try store.reconcile(pingManager: { false })
        XCTAssertTrue(result.hadTrackedWorkers)
        XCTAssertEqual(result.removedWorkerInstances, ["ubuntu"])
        XCTAssertTrue(result.managerWasCleared)
        XCTAssertNil(result.state.managerPID)
        XCTAssertTrue(result.state.workers.isEmpty)
    }
}
