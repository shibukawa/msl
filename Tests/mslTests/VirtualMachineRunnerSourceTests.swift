import XCTest

final class VirtualMachineRunnerSourceTests: XCTestCase {
    func testBootloaderTransferSendsTimezoneAsExecEnv() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/mslCore/VirtualMachineRunner.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("targetKind: .execEnv"))
        XCTAssertTrue(source.contains("entry: \"TZ=\\(hostTimeZoneID)\""))
        XCTAssertFalse(source.contains("targetKind: .environment,\n                flags: 0,\n                entry: \"TZ=\\(hostTimeZoneID)\""))
    }

    func testBootloaderTransferSendsWaylandDefaultsAsExecEnv() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/mslCore/VirtualMachineRunner.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("let waylandEnv = defaultWaylandEnvironment()"))
        XCTAssertTrue(source.contains("entry: \"\\(key)=\\(value)\""))
        XCTAssertTrue(source.contains("targetKind: .execEnv"))
    }

    func testWaylandDefaultDisplayDiagnosticsAreLogged() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/mslCore/VirtualMachineRunner.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("wayland_default_display_listener_state"))
        XCTAssertTrue(source.contains("\"default_display_listener_state\": port == 38000 ? \"installed\" : \"session\""))
        XCTAssertTrue(source.contains("wayland_display_listener_requested"))
        XCTAssertTrue(source.contains("wayland_display_listener_install_requested"))
        XCTAssertTrue(source.contains("wayland_display_connection_retained"))
        XCTAssertTrue(source.contains("wayland_display_fd_duplicated"))
        XCTAssertTrue(source.contains("wayland_display_core_attached"))
        XCTAssertTrue(source.contains("wayland_display_core_attach_failed"))
    }

    func testBootloaderTransferSendsEphemeralTmpBootstrapMetadata() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/mslCore/VirtualMachineRunner.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("MSL_EPHEMERAL_TMP_MODE=ephemeral"))
        XCTAssertTrue(source.contains("MSL_EPHEMERAL_TMP_DEVICE="))
        XCTAssertTrue(source.contains("MSL_EPHEMERAL_TMP_SIZE_MIB="))
        XCTAssertTrue(source.contains("MSL_EPHEMERAL_TMP_RESET_ON_STOP="))
        XCTAssertTrue(source.contains("ephemeralTmpDevicePath = rootMode == .readonlyBaseCowState ? \"/dev/vdc\" : \"/dev/vdb\""))
    }

    func testEphemeralTmpDiskRequiresHostMkfsHelper() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/mslCore/VirtualMachineRunner.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("tmp ext4 mkfs helper not found"))
        XCTAssertFalse(source.contains("failed to create tmp image file"))
    }

    func testReadonlyBaseCowStateAttachesBaseReadonlyAndStateWritable() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/mslCore/VirtualMachineRunner.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("diskReadOnly: metadata.rootMode == .readonlyBaseCowState"))
        XCTAssertTrue(source.contains("VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: diskReadOnly)"))
        XCTAssertTrue(source.contains("VZDiskImageStorageDeviceAttachment(url: stateDiskURL, readOnly: false)"))
        XCTAssertFalse(source.contains("initialRamdiskURL"))
        XCTAssertFalse(source.contains("makeOverlayRootInitramfs"))
    }

    func testInitialInitHandshakeRetriesAfterFirstPingFailure() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/mslCore/VirtualMachineRunner.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("for attempt in 1...2"))
        XCTAssertTrue(source.contains("init_handshake_retry_after_ping_failure"))
        XCTAssertTrue(source.contains("acceptedVsockConnection = nil"))
        XCTAssertTrue(source.contains("init_handshake_retry_succeeded"))
    }

    func testDirectInitClientUsesSidebandForStreaming() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/mslCore/VirtualMachineRunner.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("sidebandSupported: true"))
        XCTAssertTrue(source.contains("allowStreamingOnVsock: false"))
    }

    func testInitVsockConnectionsAreAssignedByHelloRole() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/mslCore/VirtualMachineRunner.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("let line = try readBootProtocolLine(fd: connection.fileDescriptor"))
        XCTAssertTrue(source.contains("let duplicated = dup(connection.fileDescriptor)"))
        XCTAssertTrue(source.contains("MSLInitBootTransferProtocol.parseHelloLine(line)"))
        XCTAssertTrue(source.contains("listenerDelegate.storeAcceptedConnection(accepted)"))
        XCTAssertTrue(source.contains("init_vsock_role_received"))
        XCTAssertTrue(source.contains("takeAcceptedConnection(role: role)"))
    }

    func testInitHandshakeStderrLogsAreDebugOnly() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/mslCore/VirtualMachineRunner.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("shouldEmitInitHandshakeStderrLogs()"))
        XCTAssertTrue(source.contains("MSL_DEBUG_INIT_HANDSHAKE"))
    }

    func testBootloaderTransferHalfClosesWriteSideAfterPayload() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/mslCore/VirtualMachineRunner.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("try writeAll(fd: connection.fd, data: payload)"))
        XCTAssertTrue(source.contains("shutdown(connection.fd, SHUT_WR)"))
        XCTAssertTrue(source.contains("init_bootloader_write_shutdown"))
    }

    func testStopRunningVMWaitsForGuestStopBeforeClearingReferences() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/mslCore/VirtualMachineRunner.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("let delegate = runningDelegate"))
        XCTAssertTrue(source.contains("waitForRunningVMStop(delegate: delegate, timeoutMs: 5_000)"))
        XCTAssertTrue(source.contains("clearRunningVMReferences()"))
        XCTAssertTrue(source.contains("private func waitForRunningVMStop(delegate: VMDelegate, timeoutMs: Int) -> Bool"))
    }
}
