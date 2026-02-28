import XCTest
@testable import mslCore

final class BootstrapManagerTests: XCTestCase {
    func testRuntimeBootstrapCompletesWithoutLegacyBootstrapLogs() throws {
        let ctx = try TestContext.make()
        defer { ctx.cleanup() }

        setenv("MSL_SKIP_SEED_IMAGE", "1", 1)
        defer { unsetenv("MSL_SKIP_SEED_IMAGE") }

        let logURL = ctx.paths.logs.appendingPathComponent("test.log", isDirectory: false)
        let logger = MSLLogger(logFile: logURL)
        let bootstrap = BootstrapManager(paths: ctx.paths, logger: logger)

        XCTAssertNoThrow(try bootstrap.ensureBootstrapped(context: .runtime))

        let logText = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(logText.contains("\"event\":\"bootstrap_completed\""))
        XCTAssertFalse(logText.contains("bootstrap_legacy_image_missing_skipped"))
        XCTAssertFalse(logText.contains("ext4_mkfs_helper_"))
        XCTAssertFalse(logText.contains("\"event\":\"ext4_helper_reused\""))
        XCTAssertFalse(logText.contains("\"event\":\"startup_path_pruned\""))
    }

    func testInstallBootstrapStagesHelpersWithoutLegacyImage() throws {
        let ctx = try TestContext.make()
        defer { ctx.cleanup() }

        let initBinary = ctx.root.appendingPathComponent("msl-init")
        let mkfsHelper = ctx.root.appendingPathComponent("msl-ext4-mkfs")
        let ext4Helper = ctx.root.appendingPathComponent("msl-ext4-image")
        var fakeElf = Data(repeating: 0, count: 64)
        fakeElf[0] = 0x7f
        fakeElf[1] = 0x45
        fakeElf[2] = 0x4c
        fakeElf[3] = 0x46
        fakeElf[4] = 0x02 // 64-bit
        fakeElf[5] = 0x01 // little endian
        fakeElf[18] = 0xb7 // e_machine low byte (AArch64 = 183)
        fakeElf[19] = 0x00 // e_machine high byte
        try fakeElf.write(to: initBinary)
        try Data("helper".utf8).write(to: mkfsHelper)
        try Data("helper".utf8).write(to: ext4Helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mkfsHelper.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ext4Helper.path)

        setenv("MSL_INIT_BINARY_PATH", initBinary.path, 1)
        setenv("MSL_EXT4_MKFS_HELPER_PATH", mkfsHelper.path, 1)
        setenv("MSL_EXT4_HELPER_PATH", ext4Helper.path, 1)
        setenv("MSL_SKIP_SEED_IMAGE", "1", 1)

        let logger = MSLLogger(logFile: ctx.paths.logs.appendingPathComponent("test.log"))
        let bootstrap = BootstrapManager(paths: ctx.paths, logger: logger)
        XCTAssertNoThrow(try bootstrap.ensureBootstrapped(context: .install))

        XCTAssertFalse(FileManager.default.fileExists(atPath: ctx.paths.defaultDistroDir.appendingPathComponent("disk.raw").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ctx.paths.defaultDistroDir.appendingPathComponent("metadata.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ctx.paths.cloudInitUserDataFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ctx.paths.cloudInitMetaDataFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ctx.paths.mslHostInitBinaryFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ctx.paths.mslHostExt4MkfsHelperBinaryFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ctx.paths.mslHostExt4HelperBinaryFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ctx.paths.cloudInitDir.appendingPathComponent("msl-init").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ctx.paths.compressionCachePolicyCatalogFile.path))

        let userData = try String(contentsOf: ctx.paths.cloudInitUserDataFile)
        XCTAssertTrue(userData.contains("output:"))
        XCTAssertTrue(userData.contains("all: \"| tee -a /var/log/cloud-init-output.log\""))
        XCTAssertTrue(userData.contains("macos /mnt/macos virtiofs"))
        XCTAssertFalse(userData.contains("mslhome /mnt/macos/home virtiofs"))
        XCTAssertTrue(userData.contains("/mnt/macos/Users/"))
        XCTAssertTrue(userData.contains("path: /etc/modules-load.d/vsock.conf"))
        XCTAssertTrue(userData.contains("/msl-home /home/"))
        XCTAssertTrue(userData.contains("path: /etc/systemd/system/serial-getty@.service.d/autologin.conf"))
        XCTAssertTrue(userData.contains("path: /etc/systemd/system/msl-init.service"))
        XCTAssertTrue(userData.contains("path: /usr/local/sbin/msl-update-init.sh"))
        XCTAssertTrue(userData.contains("path: /usr/local/sbin/msl-runcmd-step-log.sh"))
        XCTAssertTrue(userData.contains("[ mkdir, -p, /usr/local/bin ]"))
        XCTAssertTrue(userData.contains("cp /tmp/msl-seed/msl-init /usr/local/bin/msl-init && chmod 0755 /usr/local/bin/msl-init"))
        XCTAssertTrue(userData.contains("ExecStartPre=-/usr/sbin/modprobe vmw_vsock_virtio_transport"))
        XCTAssertTrue(userData.contains("Environment=MSL_INIT_LOG_FILE=/var/log/msl-init.log"))
        XCTAssertTrue(userData.contains("After=local-fs.target systemd-modules-load.service"))
        XCTAssertTrue(userData.contains("if [ -x /usr/local/bin/msl-init ]; then systemctl enable --now msl-init.service || true; fi"))
        XCTAssertTrue(userData.contains("step00-update-grub"))
        XCTAssertTrue(userData.contains("step03-mount-seed-iso"))
        XCTAssertTrue(userData.contains("seed_iso_mount=${MOUNTED}"))
        XCTAssertTrue(userData.contains("seed_iso_copy=ok"))
        XCTAssertTrue(userData.contains("seed_iso_copy=not_found"))
        XCTAssertTrue(userData.contains("step07-record-state"))
        XCTAssertTrue(userData.contains("msl_init=present >> ${LOG}"))
        XCTAssertTrue(userData.contains("ln -sf /usr/local/bin/msl-init /usr/local/bin/msl"))
        XCTAssertTrue(userData.contains("msl_cmd=present >> ${LOG}"))
        XCTAssertTrue(userData.contains("msl_init_enabled=${ENABLED} msl_init_active=${ACTIVE}"))
        XCTAssertTrue(userData.contains("cloud-init-output.log"))
        XCTAssertTrue(userData.contains("systemctl enable --now serial-getty@hvc0.service || true"))
        XCTAssertTrue(userData.contains("mount -t iso9660 -o ro"))

        unsetenv("MSL_INIT_BINARY_PATH")
        unsetenv("MSL_EXT4_MKFS_HELPER_PATH")
        unsetenv("MSL_EXT4_HELPER_PATH")
        unsetenv("MSL_SKIP_SEED_IMAGE")
    }
}

private struct TestContext {
    let root: URL
    let paths: MSLPaths

    static func make() throws -> TestContext {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-bootstrap-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = MSLPaths(homeDirectoryURL: root)
        return TestContext(root: root, paths: paths)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
