import XCTest

final class MSLInitSourceTests: XCTestCase {
    func testErofsEphemeralStateBindsWritableEtcDirectory() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Support/msl-init/src/main.rs"), encoding: .utf8)

        XCTAssertTrue(source.contains("copy_tree_best_effort(\"/etc\", \"/run/msl/tmp/etc\", \"erofs_etc_copy\")"))
        XCTAssertTrue(source.contains("bind_mount_directory_if_needed(\"/run/msl/tmp/etc\", \"/etc\")"))
        XCTAssertFalse(source.contains("for etc_name in [\"hosts\", \"resolv.conf\", \"hostname\"]"))
        XCTAssertFalse(source.contains("bind_mount_file_if_needed(&destination, &source)"))
    }

    func testMountPrerequisitesMountCgroup2Hierarchy() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Support/msl-init/src/main.rs"), encoding: .utf8)

        XCTAssertTrue(source.contains("mount_fs_if_needed(\"/sys/fs/cgroup\", b\"cgroup2\\0\", b\"cgroup2\\0\", None);"))
    }

    func testPersistentVsockConnectionDoesNotDependOnTryClone() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Support/msl-init/src/main.rs"), encoding: .utf8)

        XCTAssertTrue(source.contains("let mut stream = stream;"))
        XCTAssertTrue(source.contains("let request_frame = match read_frame(&mut stream)"))
        XCTAssertFalse(source.contains("let reader_stream = match stream.try_clone()"))
        XCTAssertFalse(source.contains("let mut reader = BufReader::new(reader_stream)"))
    }

    func testVsockConnectRetriesInterruptedConnectAsConnectedSocket() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Support/msl-init/src/main.rs"), encoding: .utf8)

        XCTAssertTrue(source.contains("fn connect_vsock_stream(port: u32)"))
        XCTAssertTrue(source.contains("raw != Some(libc::EINPROGRESS) && raw != Some(libc::EAGAIN) && raw != Some(libc::EINTR)"))
        XCTAssertTrue(source.contains("retry_err.raw_os_error() != Some(libc::EISCONN)"))
    }

    func testBootloaderDropsTransferSocketBeforeExec() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Support/msl-init/src/bin/msl-init-bootloader.rs"), encoding: .utf8)

        XCTAssertTrue(source.contains("drop(stream);"))
        XCTAssertTrue(source.contains("Close it before exec"))
    }

    func testPersistentControlAndSidebandSendRoleHello() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Support/msl-init/src/main.rs"), encoding: .utf8)

        XCTAssertTrue(source.contains("send_role_hello(&mut stream, \"control\")"))
        XCTAssertTrue(source.contains("send_role_hello(&mut stream, &format!(\"sideband:{}\", role))"))
        XCTAssertTrue(source.contains("control hello sent"))
        XCTAssertTrue(source.contains("sideband hello sent role="))
    }

    func testDirectProcReadUsesNonblockingPolling() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Support/msl-init/src/main.rs"), encoding: .utf8)

        XCTAssertTrue(source.contains("proc_read_direct_received proc_id={} requested_timeout_ms={} effective_timeout_ms=0"))
        XCTAssertTrue(source.contains("collect_proc_read_events(session, Some(0))"))
    }

    func testVsockConnectUsesNonblockingPollBeforeHello() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Support/msl-init/src/main.rs"), encoding: .utf8)

        XCTAssertTrue(source.contains("fn connect_vsock_stream(port: u32)"))
        XCTAssertTrue(source.contains("fcntl(fd, F_SETFL, flags | O_NONBLOCK)"))
        XCTAssertTrue(source.contains("events: POLLOUT"))
        XCTAssertTrue(source.contains("connect timed out waiting for writable socket"))
        XCTAssertTrue(source.contains("attempting vsock connect to host port"))
    }
}
