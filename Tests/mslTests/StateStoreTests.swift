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

        XCTAssertEqual(loaded.schemaVersion, 1)
        XCTAssertEqual(loaded.vmState, .running)
        XCTAssertEqual(loaded.activeSessionCount, 2)
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
        XCTAssertEqual(loaded.schemaVersion, 1)
        XCTAssertEqual(loaded.mappings.count, 2)
        XCTAssertEqual(loaded.mappings[0].hostPort, 8080)
        XCTAssertEqual(loaded.mappings[1].guestPort, 3001)
    }
}
