import XCTest
@testable import mslCore

final class AppManagerTests: XCTestCase {
    override func tearDown() {
        unsetenv("MSL_WORKER_REGISTER_TIMEOUT_SEC")
        super.tearDown()
    }

    func testEnsureInstanceSurfacesWorkerRuntimeStartupFailure() throws {
        setenv("MSL_WORKER_REGISTER_TIMEOUT_SEC", "2", 1)
        let ctx = try makeContext()
        defer { ctx.cleanup() }

        let worker = try ctx.writeWorkerScript(
            """
            #!/bin/sh
            EPOCH_MS=$(($(date +%s) * 1000))
            cat > "$MSL_RUNTIME_ROOT/state.json" <<EOF
            {
              "schemaVersion": 3,
              "distro": "ubuntu",
              "vmState": "Stopped",
              "lifecycleState": "error",
              "activeSessionCount": 0,
              "idleTimer": { "armed": false },
              "lastTransitionEpochMs": $EPOCH_MS,
              "startupStepName": "init_handshake_wait",
              "startupStepStatus": "failed",
              "lastErrorCode": "init_handshake_wait_failed",
              "lastErrorMessage": "init channel did not connect within 30s",
              "bootstrap": { "completed": false, "phase": "none" },
              "instances": [
                {
                  "instance": "ubuntu",
                  "vmState": "Stopped",
                  "lifecycleState": "error",
                  "activeSessionCount": 0,
                  "idleTimer": { "armed": false },
                  "lastTransitionEpochMs": $EPOCH_MS,
                  "startupStepName": "init_handshake_wait",
                  "startupStepStatus": "failed",
                  "lastErrorCode": "init_handshake_wait_failed",
                  "lastErrorMessage": "init channel did not connect within 30s"
                }
              ]
            }
            EOF
            exit 1
            """
        )
        let manager = try ctx.startManager(executablePath: worker.path)
        defer { manager.stop() }

        let response = try ctx.client.send(ManagerControlRequest(op: "ensure_instance", instance: "ubuntu"))

        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.error?.contains("init channel did not connect within 30s") == true)
        XCTAssertTrue(response.error?.contains("startup_step=init_handshake_wait") == true)
        XCTAssertTrue(response.error?.contains("code=init_handshake_wait_failed") == true)
        XCTAssertFalse(response.error?.contains("worker did not register in time") == true)
    }

    func testEnsureInstanceKeepsTimeoutWhenWorkerStaysAliveWithoutState() throws {
        setenv("MSL_WORKER_REGISTER_TIMEOUT_SEC", "0.3", 1)
        let ctx = try makeContext()
        defer { ctx.cleanup() }

        let worker = try ctx.writeWorkerScript(
            """
            #!/bin/sh
            sleep 5
            """
        )
        let manager = try ctx.startManager(executablePath: worker.path)
        defer { manager.stop() }

        let response = try ctx.client.send(ManagerControlRequest(op: "ensure_instance", instance: "ubuntu"))

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "worker did not register in time for instance 'ubuntu'")
    }

    func testEnsureInstanceReportsWorkerStartFailureWhenProcessExitsWithoutState() throws {
        setenv("MSL_WORKER_REGISTER_TIMEOUT_SEC", "2", 1)
        let ctx = try makeContext()
        defer { ctx.cleanup() }

        let worker = try ctx.writeWorkerScript(
            """
            #!/bin/sh
            exit 7
            """
        )
        let manager = try ctx.startManager(executablePath: worker.path)
        defer { manager.stop() }

        let response = try ctx.client.send(ManagerControlRequest(op: "ensure_instance", instance: "ubuntu"))

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "worker failed to start for instance 'ubuntu'")
    }

    private func makeContext() throws -> AppManagerTestContext {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("mslam-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = MSLPaths(homeDirectoryURL: root)
        let logger = MSLLogger(
            logFile: paths.logs.appendingPathComponent("test.log", isDirectory: false),
            fileManager: .default
        )
        return AppManagerTestContext(root: root, paths: paths, logger: logger)
    }
}

private struct AppManagerTestContext {
    let root: URL
    let paths: MSLPaths
    let logger: MSLLogger

    var client: ManagerControlClient {
        ManagerControlClient(socketPath: paths.managerSocketFile.path)
    }

    func writeWorkerScript(_ contents: String) throws -> URL {
        let url = root.appendingPathComponent("fake-worker.sh", isDirectory: false)
        try Data(contents.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func startManager(executablePath: String) throws -> AppManager {
        let manager = AppManager(paths: paths, fileManager: .default, logger: logger, executablePath: executablePath)
        try manager.start()
        return manager
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
