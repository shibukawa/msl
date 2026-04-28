import XCTest
@testable import mslCore

final class SessionStreamBridgeTests: XCTestCase {
    func testProcBridgeStateCompletesWhenStreamsCloseBeforeExit() {
        let state = SessionStreamBridgeState()
        state.observeOutputClosed()
        XCTAssertNil(state.snapshot.exitCode)
        state.observeExit(code: 0, reason: nil)

        let snapshot = state.snapshot
        XCTAssertTrue(snapshot.outputClosed)
        XCTAssertEqual(snapshot.exitCode, 0)
    }

    func testProcBridgeStateCompletesWhenExitObservedBeforeStreamsClose() {
        let state = SessionStreamBridgeState()
        state.observeExit(code: 17, reason: "done")
        XCTAssertFalse(state.snapshot.outputClosed)
        state.observeOutputClosed()

        let snapshot = state.snapshot
        XCTAssertTrue(snapshot.outputClosed)
        XCTAssertEqual(snapshot.exitCode, 17)
        XCTAssertEqual(snapshot.exitReason, "done")
    }

    func testProcBridgeStateRetainsFailureAlongsideCloseOrdering() {
        let state = SessionStreamBridgeState()
        state.observeOutputClosed()
        state.abort("stdout_write_failed")
        state.observeExit(code: 1, reason: "failed")

        let snapshot = state.snapshot
        XCTAssertTrue(snapshot.outputClosed)
        XCTAssertEqual(snapshot.exitCode, 1)
        XCTAssertEqual(snapshot.failureReason, "stdout_write_failed")
    }

    func testInitProcBridgeThrottlesEmptyPolls() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/mslCore/SessionStreamBridge.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("var emittedChunk = false"))
        XCTAssertTrue(source.contains("Thread.sleep(forTimeInterval: 0.02)"))
    }
}
