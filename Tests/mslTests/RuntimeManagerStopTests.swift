import XCTest
import Darwin
@testable import mslCore

final class RuntimeManagerStopTests: XCTestCase {
    func testStopSucceedsWhenManagerSocketIsMissingAndTrackedWorkerExists() throws {
        let ctx = try RuntimeManagerStopContext.make()
        defer { ctx.cleanup() }

        let paths = MSLPaths(homeDirectoryURL: ctx.root)
        let appStore = AppManagerStateStore(paths: paths, fileManager: .default)
        try appStore.save(
            AppManagerState(
                managerPID: 999_999,
                managerSocketPath: paths.managerSocketFile.path,
                managerStartedEpochMs: 10,
                workers: [
                    AppManagerWorkerRecord(
                        instanceName: "ubuntu",
                        pid: 999_998,
                        runtimeRoot: paths.workerRuntimeDirectory(named: "ubuntu").path,
                        controlSocketPath: paths.workerControlSocketFile(named: "ubuntu").path,
                        eventSocketPath: paths.workerEventSocketFile(named: "ubuntu").path,
                        lifecycleState: .running,
                        lastTransitionEpochMs: 11
                    )
                ],
                lastUpdatedEpochMs: 11
            )
        )

        let manager = try ctx.makeManager()
        XCTAssertNoThrow(try manager.stopVM(instanceName: "ubuntu", all: false))
    }

    func testStopSucceedsWhenManagerSocketExistsButRefusesConnection() throws {
        let ctx = try RuntimeManagerStopContext.make()
        defer { ctx.cleanup() }

        let paths = MSLPaths(homeDirectoryURL: ctx.root)
        try FileManager.default.createDirectory(at: paths.appControl, withIntermediateDirectories: true)
        try createStaleUnixSocket(at: paths.managerSocketFile.path)

        let appStore = AppManagerStateStore(paths: paths, fileManager: .default)
        try appStore.save(
            AppManagerState(
                managerPID: 999_999,
                managerSocketPath: paths.managerSocketFile.path,
                managerStartedEpochMs: 10,
                workers: [
                    AppManagerWorkerRecord(
                        instanceName: "ubuntu",
                        pid: 999_998,
                        runtimeRoot: paths.workerRuntimeDirectory(named: "ubuntu").path,
                        controlSocketPath: paths.workerControlSocketFile(named: "ubuntu").path,
                        eventSocketPath: paths.workerEventSocketFile(named: "ubuntu").path,
                        lifecycleState: .running,
                        lastTransitionEpochMs: 11
                    )
                ],
                lastUpdatedEpochMs: 11
            )
        )

        let manager = try ctx.makeManager()
        XCTAssertNoThrow(try manager.stopVM(instanceName: "ubuntu", all: false))
    }

    func testExplicitStopErrorsWhenInstalledInstanceWasNeverRunning() throws {
        let ctx = try RuntimeManagerStopContext.make()
        defer { ctx.cleanup() }

        let paths = MSLPaths(homeDirectoryURL: ctx.root)
        let distroDir = paths.distroDirectory(named: "ubuntu")
        try FileManager.default.createDirectory(at: distroDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.distroDiskFile(named: "ubuntu").path, contents: Data())

        let manager = try ctx.makeManager()
        XCTAssertThrowsError(try manager.stopVM(instanceName: "ubuntu", all: false)) { error in
            XCTAssertEqual(String(describing: error), "instance 'ubuntu' is not running")
        }
    }

    func testStopAppManagerSucceedsWhenManagerSocketExistsButRefusesConnection() throws {
        let ctx = try RuntimeManagerStopContext.make()
        defer { ctx.cleanup() }

        let paths = MSLPaths(homeDirectoryURL: ctx.root)
        try FileManager.default.createDirectory(at: paths.appControl, withIntermediateDirectories: true)
        try createStaleUnixSocket(at: paths.managerSocketFile.path)

        let appStore = AppManagerStateStore(paths: paths, fileManager: .default)
        try appStore.save(
            AppManagerState(
                managerPID: 999_999,
                managerSocketPath: paths.managerSocketFile.path,
                managerStartedEpochMs: 10,
                lastUpdatedEpochMs: 11
            )
        )

        let manager = try ctx.makeManager()
        XCTAssertNoThrow(try manager.stopAppManager())

        let state = try appStore.load()
        XCTAssertNil(state.managerPID)
        XCTAssertNil(state.managerSocketPath)
        XCTAssertNil(state.managerStartedEpochMs)
    }

    func testStopAppManagerSucceedsWhenNoManagerIsRunning() throws {
        let ctx = try RuntimeManagerStopContext.make()
        defer { ctx.cleanup() }

        let manager = try ctx.makeManager()
        XCTAssertNoThrow(try manager.stopAppManager())
    }

    private func createStaleUnixSocket(at path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        XCTAssertLessThan(bytes.count, capacity)
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in bytes.enumerated() {
                buffer[index] = byte
            }
        }
        unlink(path)
        var bindAddr = addr
        let result = withUnsafePointer(to: &bindAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        XCTAssertEqual(result, 0)
    }
}

private struct RuntimeManagerStopContext {
    let root: URL
    let previousMSLHome: String?

    static func make() throws -> RuntimeManagerStopContext {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("mslrt-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previous = ProcessInfo.processInfo.environment["MSL_HOME"]
        setenv("MSL_HOME", root.path, 1)
        return RuntimeManagerStopContext(root: root, previousMSLHome: previous)
    }

    func makeManager() throws -> RuntimeManager {
        try RuntimeManager(executablePath: "/bin/echo", fileManager: .default)
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
