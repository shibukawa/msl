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

    func testContainerRuntimeWorkerUsesRootStartupPath() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/mslCore/DaemonServer.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("let isContainerRuntime = initialMetadata.resolvedWorkloadKind() == .containerRuntime"))
        XCTAssertTrue(source.contains("container_runtime_user_converge_skipped"))
        XCTAssertTrue(source.contains("policyTemplateID: \"container-runtime-root-v1\""))
        XCTAssertTrue(source.contains("try prepareContainerRuntimeServicesOnStartup(client: client, instanceName: instanceName)"))
        XCTAssertTrue(source.contains("try ensureContainerRuntimeServiceManagerInitialized(client: client, instanceName: instanceName)"))
        XCTAssertTrue(source.contains("try ensureContainerRuntimeService(\"containerd\", client: client, instanceName: instanceName)"))
        XCTAssertTrue(source.contains("try ensureContainerRuntimeService(\"buildkitd\", client: client, instanceName: instanceName)"))
        XCTAssertTrue(source.contains("marker=\"$marker_dir/container-runtime-cache-policy\""))
        XCTAssertTrue(source.contains("if !isContainerRuntime {\n                let runtimeUser = instanceContext.runtimeUser?.name ?? \"root\""))
        XCTAssertTrue(source.contains("sshInfo: sshInfo"))
    }
}
