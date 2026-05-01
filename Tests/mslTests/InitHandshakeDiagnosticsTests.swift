import XCTest
@testable import mslCore

final class InitHandshakeDiagnosticsTests: XCTestCase {
    func testInitHandshakeTimeoutMessageAddsDiskHintForBtrfsCorruptionMarkers() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("msl-init-diagnostics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let serialLog = root.appendingPathComponent("serial-console.log", isDirectory: false)
        try Data(
            """
            [    1.549093] BTRFS error (device vda): parent transid verify failed on logical 51281920 mirror 1 wanted 177 found 29
            [    1.571882] systemd[1]: Failed to read symlink /etc/systemd/system/dbus.service: Input/output error
            """.utf8
        ).write(to: serialLog, options: .atomic)

        let message = VirtualMachineRunner.initHandshakeTimeoutMessage(
            timeoutSec: 30,
            role: "bootloader",
            initMode: "service-managed-init",
            serviceManager: "systemd",
            checkCommand: "systemctl status msl-init.service --no-pager",
            serialLogPath: serialLog.path
        )

        XCTAssertTrue(message.contains("init channel did not connect within 30s"))
        XCTAssertTrue(message.contains("inspect serial log at \(serialLog.path)"))
        XCTAssertTrue(message.contains("root filesystem I/O or Btrfs corruption markers"))
        XCTAssertTrue(message.contains("may need reinstall or rebuild"))
    }

    func testInitHandshakeTimeoutMessageOmitsDiskHintWithoutCorruptionMarkers() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("msl-init-diagnostics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let serialLog = root.appendingPathComponent("serial-console.log", isDirectory: false)
        try Data(
            """
            [    1.482109] systemd[1]: systemd running in system mode
            [  OK  ] Reached target multi-user.target - Multi-User System.
            """.utf8
        ).write(to: serialLog, options: .atomic)

        let message = VirtualMachineRunner.initHandshakeTimeoutMessage(
            timeoutSec: 30,
            role: "bootloader",
            initMode: "service-managed-init",
            serviceManager: "systemd",
            checkCommand: "systemctl status msl-init.service --no-pager",
            serialLogPath: serialLog.path
        )

        XCTAssertTrue(message.contains("init channel did not connect within 30s"))
        XCTAssertTrue(message.contains("inspect serial log at \(serialLog.path)"))
        XCTAssertFalse(message.contains("may need reinstall or rebuild"))
    }
}
