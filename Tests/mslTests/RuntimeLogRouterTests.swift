import XCTest
@testable import mslCore

final class RuntimeLogRouterTests: XCTestCase {
    private var tempRoot: URL!
    private var paths: MSLPaths!
    private var fileManager: FileManager!

    override func setUpWithError() throws {
        fileManager = FileManager.default
        tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("msl-tests-log-router-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        paths = MSLPaths(homeDirectoryURL: tempRoot)
    }

    override func tearDownWithError() throws {
        if let tempRoot, fileManager.fileExists(atPath: tempRoot.path) {
            try fileManager.removeItem(at: tempRoot)
        }
    }

    func testSessionLogFileCreatedAndWritable() throws {
        let router = RuntimeLogRouter(paths: paths, fileManager: fileManager)
        let file = try router.ensureSessionLogFile(instance: "ubuntu", sessionID: "s1")
        router.logSession(instance: "ubuntu", sessionID: "s1", event: "session_exec_started", fields: ["op": "exec"])
        let text = try String(contentsOf: file)
        XCTAssertTrue(text.contains("\"session_id\":\"s1\""))
        XCTAssertTrue(text.contains("\"instance\":\"ubuntu\""))
    }

    func testVMLogFileCreatedAndWritable() throws {
        let router = RuntimeLogRouter(paths: paths, fileManager: fileManager)
        router.logVM(instance: "alpine", event: "daemon_instance_boot_start", fields: ["op": "boot"])
        let file = paths.instanceVMLifecycleLogFile(named: "alpine")
        XCTAssertTrue(fileManager.fileExists(atPath: file.path))
        let text = try String(contentsOf: file)
        XCTAssertTrue(text.contains("\"instance\":\"alpine\""))
        XCTAssertTrue(text.contains("\"event\":\"daemon_instance_boot_start\""))
    }
}
