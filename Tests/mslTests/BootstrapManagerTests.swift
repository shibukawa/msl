import XCTest
@testable import mslCore

final class BootstrapManagerTests: XCTestCase {
    func testRuntimeBootstrapCompletesWithoutLegacyBootstrapLogs() throws {
        let ctx = try TestContext.make()
        defer { ctx.cleanup() }

        let logURL = ctx.paths.logs.appendingPathComponent("test.log", isDirectory: false)
        let logger = MSLLogger(logFile: logURL)
        let bootstrap = BootstrapManager(paths: ctx.paths, logger: logger)

        XCTAssertNoThrow(try bootstrap.ensureBootstrapped(context: .runtime))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ctx.paths.distroDirectory(named: "default").path))

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
        let bootloaderBinary = ctx.root.appendingPathComponent("msl-init-bootloader")
        let waylandProxyBinary = ctx.root.appendingPathComponent("msl-wayland-proxy")
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
        try fakeElf.write(to: bootloaderBinary)
        try fakeElf.write(to: waylandProxyBinary)
        try Data("helper".utf8).write(to: mkfsHelper)
        try Data("helper".utf8).write(to: ext4Helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bootloaderBinary.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mkfsHelper.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ext4Helper.path)

        setenv("MSL_INIT_BINARY_PATH", initBinary.path, 1)
        setenv("MSL_INIT_BOOTLOADER_BINARY_PATH", bootloaderBinary.path, 1)
        setenv("MSL_WAYLAND_PROXY_BINARY_PATH", waylandProxyBinary.path, 1)
        setenv("MSL_EXT4_MKFS_HELPER_PATH", mkfsHelper.path, 1)
        setenv("MSL_EXT4_HELPER_PATH", ext4Helper.path, 1)
        defer {
            unsetenv("MSL_INIT_BINARY_PATH")
            unsetenv("MSL_INIT_BOOTLOADER_BINARY_PATH")
            unsetenv("MSL_WAYLAND_PROXY_BINARY_PATH")
            unsetenv("MSL_EXT4_MKFS_HELPER_PATH")
            unsetenv("MSL_EXT4_HELPER_PATH")
        }

        let logger = MSLLogger(logFile: ctx.paths.logs.appendingPathComponent("test.log"))
        let bootstrap = BootstrapManager(paths: ctx.paths, logger: logger)
        XCTAssertNoThrow(try bootstrap.ensureBootstrapped(context: .install))

        XCTAssertFalse(FileManager.default.fileExists(atPath: ctx.paths.distroDirectory(named: "default").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ctx.paths.mslHostInitBinaryFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ctx.paths.mslHostInitBootloaderBinaryFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ctx.paths.mslHostWaylandProxyBinaryFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ctx.paths.mslHostExt4MkfsHelperBinaryFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ctx.paths.mslHostExt4HelperBinaryFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ctx.paths.compressionCachePolicyCatalogFile.path))
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
