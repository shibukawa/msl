import XCTest
@testable import mslCore

final class AppManagerStopManagerTests: XCTestCase {
    func testQuitDesktopRequestUsesRegisteredHandler() throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("mslam-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = MSLPaths(homeDirectoryURL: root)
        let logger = MSLLogger(
            logFile: paths.logs.appendingPathComponent("test.log", isDirectory: false),
            fileManager: .default
        )
        let manager = AppManager(paths: paths, fileManager: .default, logger: logger, executablePath: "/bin/echo")
        let quitExpectation = expectation(description: "quit_desktop handler")
        manager.setQuitDesktopHandler {
            quitExpectation.fulfill()
        }
        try manager.start()
        defer { manager.stop() }

        let client = ManagerControlClient(socketPath: paths.managerSocketFile.path)
        let response = try client.send(ManagerControlRequest(op: "quit_desktop"))
        XCTAssertTrue(response.ok)
        wait(for: [quitExpectation], timeout: 1.0)
    }

    func testStopManagerRequestStopsManagerAndClearsState() throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("mslam-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = MSLPaths(homeDirectoryURL: root)
        let logger = MSLLogger(
            logFile: paths.logs.appendingPathComponent("test.log", isDirectory: false),
            fileManager: .default
        )
        let manager = AppManager(paths: paths, fileManager: .default, logger: logger, executablePath: "/bin/echo")
        try manager.start()

        let client = ManagerControlClient(socketPath: paths.managerSocketFile.path)
        let response = try client.send(ManagerControlRequest(op: "stop_manager"))
        XCTAssertTrue(response.ok)

        let store = AppManagerStateStore(paths: paths, fileManager: .default)
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            let state = try store.load()
            if state.managerPID == nil && state.managerSocketPath == nil && state.managerStartedEpochMs == nil {
                XCTAssertFalse(FileManager.default.fileExists(atPath: paths.managerSocketFile.path))
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let finalState = try store.load()
        XCTFail("manager state was not cleared: \(finalState)")
    }
}
