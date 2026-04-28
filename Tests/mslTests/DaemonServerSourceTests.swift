import XCTest

final class DaemonServerSourceTests: XCTestCase {
    func testEphemeralTmpPrepareIsDelegatedToInit() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/mslCore/DaemonServer.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("tmp_mount_bootstrap_delegated"))
        XCTAssertFalse(source.contains("argv: [\"/bin/sh\", \"-lc\", Self.tmpStoragePrepareScript"))
    }

    func testInstanceMetricsIncludeContainerRuntimeSummary() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/mslCore/DaemonServer.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("containerRuntime: metadata?.resolvedWorkloadKind() == .containerRuntime"))
        XCTAssertTrue(source.contains("readContainerRuntimeMetrics(client: client)"))
        XCTAssertTrue(source.contains("rc-service containerd status"))
        XCTAssertTrue(source.contains("/usr/local/bin/nerdctl images -q"))
    }
}
