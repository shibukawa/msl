import XCTest
@testable import mslCore

final class DaemonClientTests: XCTestCase {
    func testStoppedStateKeepsBootFailureError() throws {
        let ctx = try DaemonClientTestContext.make()
        defer { ctx.cleanup() }

        let paths = MSLPaths(homeDirectoryURL: ctx.root)
        try FileManager.default.createDirectory(at: paths.runtime, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        let store = StateStore(paths: paths, fileManager: .default)
        var state = RuntimeState.initial(nowMs: nowEpochMs())
        state.distro = "ubuntu"
        state.vmState = .stopped
        state.lifecycleState = .error
        state.startupEpochMs = nowEpochMs()
        state.startupStep = 5
        state.startupStepName = "vm_start"
        state.startupStepStatus = .failed
        state.lastErrorCode = "vm_start_failed"
        state.lastErrorMessage = "failed to start VM: Invalid virtual machine configuration. The storage device attachment is invalid."
        state.instances = [
            RuntimeInstanceState(
                instance: "ubuntu",
                vmState: .stopped,
                lifecycleState: .error,
                activeSessionCount: 0,
                idleTimer: IdleTimerState(),
                runtimeUser: nil,
                initChannel: nil,
                runtimeHostPid: nil,
                runtimeControlSocket: nil,
                lastError: "failed to start VM: Invalid virtual machine configuration. The storage device attachment is invalid.",
                lastErrorCode: "vm_start_failed",
                lastErrorMessage: "failed to start VM: Invalid virtual machine configuration. The storage device attachment is invalid.",
                startupEpochMs: state.startupEpochMs,
                startupStep: 5,
                startupStepName: "vm_start",
                startupStepStatus: .failed,
                lastTransitionEpochMs: nowEpochMs()
            )
        ]
        try store.saveState(state)

        let lock = try FileLock(path: paths.lockFile.path)
        let logger = MSLLogger(logFile: paths.logs.appendingPathComponent("test.log", isDirectory: false), fileManager: .default)
        let client = DaemonClient(
            paths: paths,
            lock: lock,
            store: store,
            logger: logger,
            executablePath: "/bin/echo"
        )

        XCTAssertEqual(
            client.detectStartupStateFailure(expectedInstanceName: "ubuntu"),
            "VM start failed: step 5: vm_start: failed to start VM: Invalid virtual machine configuration. The storage device attachment is invalid."
        )
    }

    func testParseDaemonProcessListExtractsInstanceScopedDaemonProcesses() {
        let text = """
 7951 /Users/shibukawayoshiki/develop/msl/.build/arm64-apple-macosx/debug/msl --_daemon --instance ubuntu
 7784 /Users/shibukawayoshiki/develop/msl/.build/arm64-apple-macosx/debug/msl --_daemon --instance _imagewriter
 1234 /usr/bin/other
"""
        XCTAssertEqual(
            DaemonClient.parseDaemonProcessList(text),
            [
                DaemonProcessInfo(
                    pid: 7951,
                    command: "/Users/shibukawayoshiki/develop/msl/.build/arm64-apple-macosx/debug/msl --_daemon --instance ubuntu",
                    instanceName: "ubuntu"
                ),
                DaemonProcessInfo(
                    pid: 7784,
                    command: "/Users/shibukawayoshiki/develop/msl/.build/arm64-apple-macosx/debug/msl --_daemon --instance _imagewriter",
                    instanceName: "_imagewriter"
                )
            ]
        )
    }

    func testDetectStaleDaemonCandidatesFindsStoppedStateWithoutSocket() throws {
        let ctx = try DaemonClientTestContext.make()
        defer { ctx.cleanup() }

        let paths = MSLPaths(homeDirectoryURL: ctx.root)
        try FileManager.default.createDirectory(at: paths.runtime, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        let lock = try FileLock(path: paths.lockFile.path)
        let store = StateStore(paths: paths, fileManager: .default)
        let logger = MSLLogger(logFile: paths.logs.appendingPathComponent("test.log", isDirectory: false), fileManager: .default)
        let client = DaemonClient(
            paths: paths,
            lock: lock,
            store: store,
            logger: logger,
            executablePath: "/bin/echo",
            processInfoProvider: {
                [
                    DaemonProcessInfo(pid: 7951, command: "/tmp/msl --_daemon --instance ubuntu", instanceName: "ubuntu")
                ]
            }
        )

        var state = RuntimeState.initial(nowMs: nowEpochMs())
        state.distro = "ubuntu"
        state.vmState = .stopped
        state.lifecycleState = .stopped
        state.runtimeHostPid = 7951
        state.daemonHostPid = 7951
        state.instances = [
            RuntimeInstanceState(
                instance: "ubuntu",
                vmState: .stopped,
                lifecycleState: .stopped,
                activeSessionCount: 0,
                idleTimer: IdleTimerState(),
                runtimeUser: nil,
                initChannel: nil,
                runtimeHostPid: 7951,
                runtimeControlSocket: nil,
                lastError: nil,
                lastTransitionEpochMs: nowEpochMs()
            )
        ]

        let candidates = client.detectStaleDaemonCandidates(state: state, expectedInstanceName: "ubuntu")
        XCTAssertEqual(candidates.map(\.pid), [7951])
    }

    func testDetectStaleDaemonCandidatesFlagsRunningStateWithoutSocket() throws {
        let ctx = try DaemonClientTestContext.make()
        defer { ctx.cleanup() }

        let paths = MSLPaths(homeDirectoryURL: ctx.root)
        try FileManager.default.createDirectory(at: paths.runtime, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        let lock = try FileLock(path: paths.lockFile.path)
        let store = StateStore(paths: paths, fileManager: .default)
        let logger = MSLLogger(logFile: paths.logs.appendingPathComponent("test.log", isDirectory: false), fileManager: .default)
        let client = DaemonClient(
            paths: paths,
            lock: lock,
            store: store,
            logger: logger,
            executablePath: "/bin/echo",
            processInfoProvider: {
                [
                    DaemonProcessInfo(pid: 7951, command: "/tmp/msl --_daemon --instance ubuntu", instanceName: "ubuntu")
                ]
            }
        )

        var state = RuntimeState.initial(nowMs: nowEpochMs())
        state.distro = "ubuntu"
        state.vmState = .running
        state.lifecycleState = .running
        state.runtimeHostPid = 7951
        state.daemonHostPid = 7951
        state.instances = [
            RuntimeInstanceState(
                instance: "ubuntu",
                vmState: .running,
                lifecycleState: .running,
                activeSessionCount: 1,
                idleTimer: IdleTimerState(),
                runtimeUser: nil,
                initChannel: nil,
                runtimeHostPid: 7951,
                runtimeControlSocket: nil,
                lastError: nil,
                lastTransitionEpochMs: nowEpochMs()
            )
        ]

        let candidates = client.detectStaleDaemonCandidates(state: state, expectedInstanceName: "ubuntu")
        XCTAssertEqual(candidates.map(\.pid), [7951])
    }

    func testDetectStaleDaemonCandidatesDoesNotFlagStartingStateWithoutSocket() throws {
        let ctx = try DaemonClientTestContext.make()
        defer { ctx.cleanup() }

        let paths = MSLPaths(homeDirectoryURL: ctx.root)
        try FileManager.default.createDirectory(at: paths.runtime, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        let lock = try FileLock(path: paths.lockFile.path)
        let store = StateStore(paths: paths, fileManager: .default)
        let logger = MSLLogger(logFile: paths.logs.appendingPathComponent("test.log", isDirectory: false), fileManager: .default)
        let client = DaemonClient(
            paths: paths,
            lock: lock,
            store: store,
            logger: logger,
            executablePath: "/bin/echo",
            processInfoProvider: {
                [
                    DaemonProcessInfo(pid: 7951, command: "/tmp/msl --_daemon --instance ubuntu", instanceName: "ubuntu")
                ]
            }
        )

        var state = RuntimeState.initial(nowMs: nowEpochMs())
        state.distro = "ubuntu"
        state.vmState = .stopped
        state.lifecycleState = .starting
        state.runtimeHostPid = 7951
        state.daemonHostPid = 7951
        state.instances = [
            RuntimeInstanceState(
                instance: "ubuntu",
                vmState: .stopped,
                lifecycleState: .starting,
                activeSessionCount: 0,
                idleTimer: IdleTimerState(),
                runtimeUser: nil,
                initChannel: nil,
                runtimeHostPid: 7951,
                runtimeControlSocket: nil,
                lastError: nil,
                lastTransitionEpochMs: nowEpochMs()
            )
        ]

        let candidates = client.detectStaleDaemonCandidates(state: state, expectedInstanceName: "ubuntu")
        XCTAssertTrue(candidates.isEmpty)
    }
}

private struct DaemonClientTestContext {
    let root: URL
    let previousMSLHome: String?

    static func make() throws -> DaemonClientTestContext {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-daemon-client-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previous = ProcessInfo.processInfo.environment["MSL_HOME"]
        setenv("MSL_HOME", root.path, 1)
        return DaemonClientTestContext(root: root, previousMSLHome: previous)
    }

    func cleanup() {
        if let previousMSLHome {
            setenv("MSL_HOME", previousMSLHome, 1)
        } else {
            unsetenv("MSL_HOME")
        }
        try? FileManager.default.removeItem(at: root)
    }
}
