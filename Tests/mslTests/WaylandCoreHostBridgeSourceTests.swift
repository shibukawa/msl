import XCTest

final class WaylandCoreHostBridgeSourceTests: XCTestCase {
    func testWaylandCoreBridgeWritesDedicatedDiagnosticsLog() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/mslCore/WaylandCoreHostBridge.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("wayland-core.log"))
        XCTAssertTrue(source.contains("wayland_core_library_loaded"))
        XCTAssertTrue(source.contains("wayland_core_start_result"))
        XCTAssertTrue(source.contains("wayland_core_attach_display_requested"))
        XCTAssertTrue(source.contains("wayland_core_attach_display_result"))
        XCTAssertTrue(source.contains("setFrameEventHandler"))
        XCTAssertTrue(source.contains("setSharedFrameEventHandler"))
        XCTAssertTrue(source.contains("setIMEEventHandler"))
        XCTAssertTrue(source.contains("handleSharedFrameCallback"))
        XCTAssertTrue(source.contains("handleIMEStateCallback"))
        XCTAssertTrue(source.contains("latestSharedFrame"))
        XCTAssertTrue(source.contains("Set(latestFrames.keys).union(latestSharedFrames.keys)"))
        XCTAssertTrue(source.contains("frameSnapshotPath(sessionID: String)"))
        XCTAssertTrue(source.contains("let handler = lock.withLock { frameEventHandler }"))
        XCTAssertTrue(source.contains("handler?(frame)"))
        XCTAssertTrue(source.contains("appendCoreLog"))
    }
}
