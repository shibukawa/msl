import XCTest
@testable import mslCore

final class DaemonStartupStateNormalizerTests: XCTestCase {
    func testNormalizeForDaemonStartResetsLegacyAndInstanceStaleState() throws {
        let nowMs: Int64 = 123_456
        var state = RuntimeState(
            schemaVersion: 2,
            distro: "ubuntu",
            vmState: .running,
            activeSessionCount: 3,
            idleTimer: IdleTimerState(armed: true, deadlineEpochMs: 99_999),
            lastTransitionEpochMs: 10,
            bootstrap: BootstrapState(completed: true, phase: "runtime"),
            runtimeHostPid: 4242,
            runtimeControlSocket: "/tmp/old-control.sock",
            initChannel: InitChannelState(version: 1, lastHeartbeatEpochMs: 11, lastStatus: .ok),
            runtimeUser: RuntimeUserState(
                name: "alice",
                uid: 1000,
                gid: 1000,
                home: "/home/alice",
                shell: "/bin/sh",
                policyTemplateID: "ubuntu-default",
                lastConvergedEpochMs: 12
            ),
            daemonHostPid: 4242,
            daemonControlSocket: "/tmp/old-control.sock",
            daemonEventSocket: nil,
            instances: [
                RuntimeInstanceState(
                    instance: "ubuntu",
                    vmState: .running,
                    activeSessionCount: 2,
                    idleTimer: IdleTimerState(armed: true, deadlineEpochMs: 88_888),
                    runtimeUser: RuntimeUserState(
                        name: "alice",
                        uid: 1000,
                        gid: 1000,
                        home: "/home/alice",
                        shell: "/bin/sh",
                        policyTemplateID: "ubuntu-default",
                        lastConvergedEpochMs: 12
                    ),
                    initChannel: InitChannelState(version: 1, lastHeartbeatEpochMs: 11, lastStatus: .ok),
                    runtimeHostPid: 4242,
                    runtimeControlSocket: "/tmp/old-control.sock",
                    lastError: "old",
                    lastTransitionEpochMs: 20
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
                    lastTransitionEpochMs: 30
                )
            ]
        )

        let summary = DaemonStartupStateNormalizer.normalizeForDaemonStart(state: &state, nowMs: nowMs)

        XCTAssertTrue(summary.legacyStateReset)
        XCTAssertEqual(summary.normalizedInstances, ["ubuntu"])

        XCTAssertEqual(state.vmState, .stopped)
        XCTAssertEqual(state.activeSessionCount, 0)
        XCTAssertFalse(state.idleTimer.armed)
        XCTAssertNil(state.idleTimer.deadlineEpochMs)
        XCTAssertNil(state.runtimeHostPid)
        XCTAssertNil(state.runtimeControlSocket)
        XCTAssertNil(state.runtimeUser)
        XCTAssertNil(state.initChannel)
        XCTAssertEqual(state.lastTransitionEpochMs, nowMs)

        let ubuntu = try XCTUnwrap(state.instances?.first(where: { $0.instance == "ubuntu" }))
        XCTAssertEqual(ubuntu.vmState, .stopped)
        XCTAssertEqual(ubuntu.activeSessionCount, 0)
        XCTAssertFalse(ubuntu.idleTimer.armed)
        XCTAssertNil(ubuntu.idleTimer.deadlineEpochMs)
        XCTAssertNil(ubuntu.runtimeHostPid)
        XCTAssertNil(ubuntu.runtimeControlSocket)
        XCTAssertNil(ubuntu.runtimeUser)
        XCTAssertNil(ubuntu.initChannel)
        XCTAssertNil(ubuntu.lastError)
        XCTAssertEqual(ubuntu.lastTransitionEpochMs, nowMs)
    }

    func testNormalizeForDaemonStartKeepsCleanStoppedState() {
        let nowMs: Int64 = 222_222
        var state = RuntimeState.initial(nowMs: 111_111)

        let summary = DaemonStartupStateNormalizer.normalizeForDaemonStart(state: &state, nowMs: nowMs)

        XCTAssertFalse(summary.legacyStateReset)
        XCTAssertTrue(summary.normalizedInstances.isEmpty)
        XCTAssertEqual(state.vmState, .stopped)
        XCTAssertEqual(state.activeSessionCount, 0)
        XCTAssertNil(state.runtimeHostPid)
        XCTAssertNil(state.runtimeControlSocket)
    }
}
