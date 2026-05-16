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
        XCTAssertTrue(source.contains("startContainerRuntimeDedupeIfAvailable(client: client, instanceName: instanceName)"))
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
            "image_storage_summary",
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

    func testWaylandLaunchUsesInitIntegratedProxy() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/mslCore/DaemonServer.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("startWaylandProxy"))
        XCTAssertTrue(source.contains("waylandProxyStart"))
        XCTAssertTrue(source.contains("mslWaylandProfileScript()"))
        XCTAssertFalse(source.contains("missing_wayland_proxy"))
        XCTAssertFalse(source.contains("exec \"$proxy_bin\" --display \"$display_name\" --port \"$display_port\" -- \"$@\""))
    }

    func testWaylandFrameEventsArePublishedAndServed() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/mslCore/DaemonServer.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("setFrameEventHandler"))
        XCTAssertTrue(source.contains("publishGUIFrameEvent"))
        XCTAssertTrue(source.contains("topic: \"gui_frame\""))
        XCTAssertTrue(source.contains("type: \"frame_available\""))
        XCTAssertTrue(source.contains("wayland_frame_event_published"))
        XCTAssertTrue(source.contains("gui_frame_latest_served"))
        XCTAssertTrue(source.contains("gui_frame_latest_shared_served"))
        XCTAssertTrue(source.contains("publishGUISharedFrameEvent"))
        XCTAssertTrue(source.contains("publishGUIWindowEvent"))
        XCTAssertTrue(source.contains("publishGUIIMEEvent"))
        XCTAssertTrue(source.contains("topic: \"gui_window_event\""))
        XCTAssertTrue(source.contains("clearSessionFrames(sessionID: event.sessionId)"))
        XCTAssertTrue(source.contains("\"frameEncoding\": \"posixShm\""))
        XCTAssertTrue(source.contains("frame too large for control channel"))
        XCTAssertTrue(source.contains("frameSnapshotPath"))
        XCTAssertTrue(source.contains("\"frameEncoding\"] = \"jsonSnapshot\""))
    }

    func testWaylandInputOpsForwardToHostCore() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/mslCore/DaemonServer.swift"), encoding: .utf8)
        let bridge = try String(contentsOf: root.appendingPathComponent("Sources/mslCore/WaylandCoreHostBridge.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains(#"case "gui_send_pointer":"#))
        XCTAssertTrue(source.contains(#"case "gui_send_keyboard":"#))
        XCTAssertTrue(source.contains(#"case "gui_send_ime_state":"#))
        XCTAssertTrue(source.contains(#"case "gui_keyboard_status":"#))
        XCTAssertTrue(source.contains(#"case "gui_keyboard_inject":"#))
        XCTAssertTrue(source.contains(#"case "gui_send_focus":"#))
        XCTAssertTrue(source.contains(#"case "gui_set_geometry":"#))
        XCTAssertTrue(source.contains(#"case "gui_request_close":"#))
        XCTAssertTrue(source.contains("WaylandCoreHostBridge.shared.sendPointer"))
        XCTAssertTrue(source.contains("WaylandCoreHostBridge.shared.sendKeyboard"))
        XCTAssertTrue(source.contains("WaylandCoreHostBridge.shared.sendIMEState"))
        XCTAssertTrue(source.contains("WaylandCoreHostBridge.shared.keyboardDebugSnapshot"))
        XCTAssertTrue(source.contains("handleGUIKeyboardInject"))
        XCTAssertTrue(source.contains("WaylandCoreHostBridge.shared.requestClose"))
        XCTAssertTrue(source.contains(#""traceId": traceID"#))
        XCTAssertTrue(source.contains(#""modifiers": String(modifiers)"#))
        XCTAssertTrue(bridge.contains("core_send_pointer"))
        XCTAssertTrue(bridge.contains("core_send_keyboard"))
        XCTAssertTrue(bridge.contains("core_send_keyboard_trace"))
        XCTAssertTrue(bridge.contains("core_keyboard_debug_snapshot"))
        XCTAssertTrue(bridge.contains("core_request_toplevel_close"))
    }

    func testContainerRuntimeSummaryReportsDedupeWithoutBlockingRuntimeHealth() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/mslCore/DaemonServer.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("rc-service msl-btrfs-dedupe status"))
        XCTAssertTrue(source.contains("dedupeEnabled: dedupeStatus != 127"))
        XCTAssertTrue(source.contains("dedupeHealthy: dedupeStatus == 0"))
        XCTAssertTrue(source.contains("container_runtime_dedupe_start_failed"))
        XCTAssertFalse(source.contains("try ensureContainerRuntimeService(\"msl-btrfs-dedupe\""))
    }

    func testImageStorageSummaryUsesStructuredImageInspectAndHostDiskAccounting() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/mslCore/DaemonServer.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("private func handleImageStorageSummary(_ request: RuntimeControlRequest) -> RuntimeControlResponse"))
        XCTAssertTrue(source.contains("parseNerdctlImageInspectList(inspectOutput).compactMap(\\.sizeBytes).reduce(0, +)"))
        XCTAssertTrue(source.contains("readContainerRuntimeHostImageStorageSummary(request)"))
        XCTAssertTrue(source.contains("paths.distroStateTemplateDiskFile(named: instanceName)"))
        XCTAssertTrue(source.contains("hostLogicalBytes: hostStorage.logical"))
        XCTAssertTrue(source.contains("hostAllocatedBytes: hostStorage.allocated"))
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
