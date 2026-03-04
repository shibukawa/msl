import XCTest
@testable import mslCore

final class StateStoreTests: XCTestCase {
    func testStateRoundTrip() throws {
        let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpHome) }

        let paths = MSLPaths(homeDirectoryURL: tmpHome)
        try FileManager.default.createDirectory(at: paths.runtime, withIntermediateDirectories: true)

        let store = StateStore(paths: paths)
        var state = RuntimeState.initial(nowMs: nowEpochMs())
        state.vmState = .running
        state.activeSessionCount = 2

        try store.saveState(state)
        let loaded = try store.loadState()

        XCTAssertEqual(loaded.schemaVersion, 2)
        XCTAssertEqual(loaded.vmState, .running)
        XCTAssertEqual(loaded.activeSessionCount, 2)
        XCTAssertEqual(loaded.instances?.first?.instance, loaded.distro)
    }

    func testInitialStateDefaults() {
        let state = RuntimeState.initial(nowMs: 100)
        XCTAssertEqual(state.vmState, .stopped)
        XCTAssertEqual(state.activeSessionCount, 0)
        XCTAssertFalse(state.idleTimer.armed)
        XCTAssertNil(state.runtimeHostPid)
        XCTAssertNil(state.runtimeControlSocket)
        XCTAssertNil(state.initChannel)
    }

    func testStateRoundTripWithInitChannelState() throws {
        let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpHome) }

        let paths = MSLPaths(homeDirectoryURL: tmpHome)
        try FileManager.default.createDirectory(at: paths.runtime, withIntermediateDirectories: true)

        let store = StateStore(paths: paths)
        var state = RuntimeState.initial(nowMs: nowEpochMs())
        state.initChannel = InitChannelState(
            version: 1,
            lastHeartbeatEpochMs: 1234,
            lastStatus: .ok,
            lastErrorCode: nil,
            lastErrorMessage: nil
        )
        try store.saveState(state)

        let loaded = try store.loadState()
        XCTAssertEqual(loaded.initChannel?.version, 1)
        XCTAssertEqual(loaded.initChannel?.lastHeartbeatEpochMs, 1234)
        XCTAssertEqual(loaded.initChannel?.lastStatus, .ok)
    }

    func testStateRoundTripWithRuntimeUser() throws {
        let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpHome) }

        let paths = MSLPaths(homeDirectoryURL: tmpHome)
        try FileManager.default.createDirectory(at: paths.runtime, withIntermediateDirectories: true)

        let store = StateStore(paths: paths)
        var state = RuntimeState.initial(nowMs: nowEpochMs())
        state.runtimeUser = RuntimeUserState(
            name: "alice",
            uid: 501,
            gid: 20,
            home: "/home/alice",
            shell: "/bin/bash",
            policyTemplateID: "ubuntu-useradd-v1",
            lastConvergedEpochMs: 12345
        )
        try store.saveState(state)

        let loaded = try store.loadState()
        XCTAssertEqual(loaded.runtimeUser?.name, "alice")
        XCTAssertEqual(loaded.runtimeUser?.uid, 501)
        XCTAssertEqual(loaded.runtimeUser?.gid, 20)
        XCTAssertEqual(loaded.runtimeUser?.home, "/home/alice")
        XCTAssertEqual(loaded.runtimeUser?.shell, "/bin/bash")
        XCTAssertEqual(loaded.runtimeUser?.policyTemplateID, "ubuntu-useradd-v1")
        XCTAssertEqual(loaded.runtimeUser?.lastConvergedEpochMs, 12345)
    }

    func testPortMappingsRoundTrip() throws {
        let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpHome) }

        let paths = MSLPaths(homeDirectoryURL: tmpHome)
        try FileManager.default.createDirectory(at: paths.runtime, withIntermediateDirectories: true)

        let store = StateStore(paths: paths)
        let state = PortMappingsState(mappings: [
            PortMapping(hostPort: 8080, guestPort: 8080),
            PortMapping(hostPort: 3000, guestPort: 3001)
        ])
        try store.savePortMappings(state)

        let loaded = try store.loadPortMappings()
        XCTAssertEqual(loaded.schemaVersion, 2)
        XCTAssertEqual(loaded.mappings.count, 2)
        XCTAssertEqual(loaded.mappings[0].hostPort, 8080)
        XCTAssertEqual(loaded.mappings[1].guestPort, 3001)
        XCTAssertEqual(loaded.mappings[0].instance, "default")
        XCTAssertEqual(loaded.mappings[1].source, "manual")
    }

    func testLegacyStateV1IsMigratedToV2() throws {
        let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpHome) }

        let paths = MSLPaths(homeDirectoryURL: tmpHome)
        try FileManager.default.createDirectory(at: paths.runtime, withIntermediateDirectories: true)

        let legacy = """
        {
          "schemaVersion": 1,
          "distro": "legacy",
          "vmState": "Running",
          "activeSessionCount": 1,
          "idleTimer": { "armed": false },
          "lastTransitionEpochMs": 123,
          "bootstrap": { "completed": false, "phase": "none" },
          "runtimeHostPid": 999,
          "runtimeControlSocket": "/tmp/legacy.sock"
        }
        """
        try legacy.data(using: .utf8)?.write(to: paths.stateFile, options: .atomic)

        let store = StateStore(paths: paths)
        let migrated = try store.loadState()

        XCTAssertEqual(migrated.schemaVersion, 2)
        XCTAssertEqual(migrated.instances?.count, 1)
        XCTAssertEqual(migrated.instances?.first?.instance, "legacy")
        XCTAssertEqual(migrated.instances?.first?.vmState, .running)
        XCTAssertEqual(migrated.instances?.first?.runtimeHostPid, 999)
        XCTAssertEqual(migrated.daemonHostPid, 999)
        XCTAssertEqual(migrated.daemonControlSocket, "/tmp/legacy.sock")
    }

    func testNormalizeDeduplicatesDuplicateInstanceEntries() throws {
        let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpHome) }

        let paths = MSLPaths(homeDirectoryURL: tmpHome)
        try FileManager.default.createDirectory(at: paths.runtime, withIntermediateDirectories: true)

        let store = StateStore(paths: paths)
        var state = RuntimeState.initial(nowMs: 100)
        state.distro = "ubuntu"
        state.vmState = .stopped
        state.instances = [
            RuntimeInstanceState(
                instance: "ubuntu",
                vmState: .stopped,
                activeSessionCount: 0,
                idleTimer: IdleTimerState(armed: false, deadlineEpochMs: nil),
                runtimeUser: nil,
                initChannel: nil,
                runtimeHostPid: nil,
                runtimeControlSocket: nil,
                lastError: nil,
                lastTransitionEpochMs: 100
            ),
            RuntimeInstanceState(
                instance: "ubuntu",
                vmState: .running,
                activeSessionCount: 1,
                idleTimer: IdleTimerState(armed: false, deadlineEpochMs: nil),
                runtimeUser: nil,
                initChannel: nil,
                runtimeHostPid: 111,
                runtimeControlSocket: "/tmp/old.sock",
                lastError: nil,
                lastTransitionEpochMs: 99
            ),
            RuntimeInstanceState(
                instance: "alpine",
                vmState: .stopped,
                activeSessionCount: 0,
                idleTimer: IdleTimerState(armed: false, deadlineEpochMs: nil),
                runtimeUser: nil,
                initChannel: nil,
                runtimeHostPid: nil,
                runtimeControlSocket: nil,
                lastError: nil,
                lastTransitionEpochMs: 98
            )
        ]

        try store.saveState(state)
        let loaded = try store.loadState()
        XCTAssertEqual(loaded.instances?.map(\.instance), ["ubuntu", "alpine"])
        XCTAssertEqual(loaded.instances?.count, 2)
        XCTAssertEqual(loaded.instances?.first?.vmState, .stopped)
    }
}
