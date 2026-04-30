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

    func testContainerMonitoringRPCsUseNerdctlThroughInitChannel() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/mslCore/DaemonServer.swift"), encoding: .utf8)

        for op in [
            "container_runtime_summary",
            "container_ls",
            "container_inspect",
            "container_stats",
            "container_stats_batch",
            "container_start",
            "container_stop",
            "container_restart",
            "container_rm",
            "image_ls",
            "image_inspect",
            "image_rm",
            "container_prune",
            "image_prune"
        ] {
            XCTAssertTrue(source.contains("case \"\(op)\""), "missing RPC op \(op)")
        }
        XCTAssertTrue(source.contains("\"/usr/local/bin/nerdctl\", \"--snapshotter\", \"native\""))
        XCTAssertTrue(source.contains("runAsRoot: true"))
        XCTAssertTrue(source.contains("parseNerdctlJSONLines"))
        XCTAssertTrue(source.contains("parseNerdctlContainerInspect"))
        XCTAssertTrue(source.contains("parseNerdctlContainerStats"))
        XCTAssertTrue(source.contains("handleContainerStatsBatch"))
        XCTAssertTrue(source.contains("containerStatsList"))
    }

    func testContainerStatsFallsBackToCgroupProbeWhenNerdctlStatsAreEmpty() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/mslCore/DaemonServer.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("stats.needsCgroupFallback"))
        XCTAssertTrue(source.contains("readContainerCgroupStats"))
        XCTAssertTrue(source.contains("memory.current"))
        XCTAssertTrue(source.contains("memory.max"))
        XCTAssertTrue(source.contains("cpu.stat"))
        XCTAssertTrue(source.contains("pids.current"))
        XCTAssertTrue(source.contains("previousContainerCPUSamples"))
        XCTAssertTrue(source.contains("memoryLimitUnlimited"))
    }

    func testContainerListParserNormalizesStatusAndStateFallbacks() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/mslCore/DaemonServer.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("let status = nonEmptyStringValue(object, [\"Status\", \"STATUS\"])"))
        XCTAssertTrue(source.contains("let state = nonEmptyStringValue(object, [\"State\", \"STATE\"])"))
        XCTAssertTrue(source.contains("status: status ?? state"))
        XCTAssertTrue(source.contains("state: state ?? compactContainerState(from: status)"))
        XCTAssertTrue(source.contains("private func compactContainerState(from status: String?) -> String?"))
        XCTAssertTrue(source.contains("lowercased.hasPrefix(\"created\")"))
        XCTAssertTrue(source.contains("lowercased.hasPrefix(\"exited\")"))
        XCTAssertTrue(source.contains("lowercased == \"up\" || lowercased.hasPrefix(\"up \")"))
    }
}
