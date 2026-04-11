import XCTest
@testable import mslCore

final class LocalhostSSHTests: XCTestCase {
    func testInfoWritesSharedConfigIncludingInstanceConfigs() throws {
        let ctx = try LocalhostSSHTestContext.make()
        defer { ctx.cleanup() }

        let manager = try ctx.makeManager()
        let info = try manager.info(instanceName: "ubuntu", requestedPort: 2222)

        XCTAssertEqual(info.sharedConfigPath, ctx.paths.sshSharedConfigFile.path)
        let sharedConfig = try String(contentsOf: ctx.paths.sshSharedConfigFile, encoding: .utf8)
        XCTAssertTrue(sharedConfig.contains("Include "))
        XCTAssertTrue(sharedConfig.contains("instances/*/ssh_config"))
        XCTAssertTrue(sharedConfig.contains("Application\\ Support"))
    }
}

private struct LocalhostSSHTestContext {
    let root: URL
    let paths: MSLPaths
    let logger: MSLLogger

    static func make() throws -> LocalhostSSHTestContext {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-localhost-ssh-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = MSLPaths(homeDirectoryURL: root)
        try FileManager.default.createDirectory(at: paths.runtime, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.sshDir, withIntermediateDirectories: true)
        let logger = MSLLogger(logFile: paths.logs.appendingPathComponent("test.log", isDirectory: false), fileManager: .default)
        return LocalhostSSHTestContext(root: root, paths: paths, logger: logger)
    }

    func makeManager() throws -> LocalhostSSHManager {
        let lock = try FileLock(path: paths.lockFile.path)
        let store = StateStore(paths: paths, fileManager: .default)
        return LocalhostSSHManager(
            paths: paths,
            lock: lock,
            store: store,
            logger: logger,
            executablePath: "/usr/bin/true",
            fileManager: .default
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
