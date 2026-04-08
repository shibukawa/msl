import XCTest
@testable import mslCore

final class RuntimeManagerAttachTerminationTests: XCTestCase {
    func testDisconnectErrorsAreRecognized() {
        XCTAssertTrue(RuntimeManager.isInteractiveShellAttachDisconnectError("broken pipe"))
        XCTAssertTrue(RuntimeManager.isInteractiveShellAttachDisconnectError("socket is not connected"))
        XCTAssertTrue(RuntimeManager.isInteractiveShellAttachDisconnectError("No such file or directory"))
        XCTAssertFalse(RuntimeManager.isInteractiveShellAttachDisconnectError("timeout waiting for PTY output"))
    }

    func testAttachStateEndsWhenDaemonPidIsMissing() throws {
        let ctx = try RuntimeManagerAttachTerminationContext.make()
        defer { ctx.cleanup() }

        let manager = try ctx.makeManager()
        XCTAssertTrue(manager.hasInteractiveShellAttachStateEnded())
    }

    func testAttachStateStaysActiveWhileDaemonPidAndSocketExist() throws {
        let ctx = try RuntimeManagerAttachTerminationContext.make()
        defer { ctx.cleanup() }

        _ = try ctx.makeManager()
        let socketPath = ctx.root.appendingPathComponent("runtime/control.sock", isDirectory: false)
        try FileManager.default.createDirectory(at: socketPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: socketPath.path, contents: Data())

        let paths = MSLPaths(homeDirectoryURL: ctx.root)
        let store = StateStore(paths: paths, fileManager: .default)
        var state = RuntimeState.initial(nowMs: nowEpochMs())
        state.daemonHostPid = getpid()
        state.runtimeHostPid = getpid()
        state.daemonControlSocket = socketPath.path
        state.runtimeControlSocket = socketPath.path
        try store.saveState(state)

        let manager = try ctx.makeManager()
        XCTAssertFalse(manager.hasInteractiveShellAttachStateEnded())
    }
}

private struct RuntimeManagerAttachTerminationContext {
    let root: URL
    let previousMSLHome: String?

    static func make() throws -> RuntimeManagerAttachTerminationContext {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-runtime-manager-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previous = ProcessInfo.processInfo.environment["MSL_HOME"]
        setenv("MSL_HOME", root.path, 1)
        return RuntimeManagerAttachTerminationContext(root: root, previousMSLHome: previous)
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
