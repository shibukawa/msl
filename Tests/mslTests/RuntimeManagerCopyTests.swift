import XCTest
@testable import mslCore

final class RuntimeManagerCopyTests: XCTestCase {
    func testBuildsRemoteFileUploadCommandWithDirectoryFallback() throws {
        let ctx = try RuntimeManagerCopyTestContext.make()
        defer { ctx.cleanup() }

        let manager = try RuntimeManager(executablePath: "/usr/bin/true", fileManager: .default)
        let command = manager.makeRemoteFileUploadCommand(
            localBaseName: "local.txt",
            remotePath: "/tmp/out path"
        )

        XCTAssertTrue(command.contains("dest='/tmp/out path'"))
        XCTAssertTrue(command.contains("base='local.txt'"))
        XCTAssertTrue(command.contains("if [ -d \"$dest\" ]; then dest=\"$dest/$base\"; fi"))
        XCTAssertTrue(command.contains("exec cat > \"$dest\""))
    }

    func testBuildsRemoteFileUploadCommandForGuestHomePath() throws {
        let ctx = try RuntimeManagerCopyTestContext.make()
        defer { ctx.cleanup() }

        let manager = try RuntimeManager(executablePath: "/usr/bin/true", fileManager: .default)
        let command = manager.makeRemoteFileUploadCommand(
            localBaseName: "local.txt",
            remotePath: "~/out path"
        )

        XCTAssertTrue(command.contains("dest=\"$HOME\"/'out path'"))
    }

    func testBuildsRemoteFileUploadCommandForGuestRelativePathUnderHome() throws {
        let ctx = try RuntimeManagerCopyTestContext.make()
        defer { ctx.cleanup() }

        let manager = try RuntimeManager(executablePath: "/usr/bin/true", fileManager: .default)
        let command = manager.makeRemoteFileUploadCommand(
            localBaseName: "local.txt",
            remotePath: "docs/out.txt"
        )

        XCTAssertTrue(command.contains("dest=\"$HOME\"/'docs/out.txt'"))
    }

    func testBuildsRemoteDirectoryUploadCommandUsingTarStream() throws {
        let ctx = try RuntimeManagerCopyTestContext.make()
        defer { ctx.cleanup() }

        let manager = try RuntimeManager(executablePath: "/usr/bin/true", fileManager: .default)
        let command = manager.makeRemoteDirectoryUploadCommand(
            localBaseName: "project",
            remotePath: "/tmp/target"
        )

        XCTAssertTrue(command.contains("dest='/tmp/target'"))
        XCTAssertTrue(command.contains("src_base='project'"))
        XCTAssertTrue(command.contains("exec tar -xf - -C \"$dest\""))
        XCTAssertTrue(command.contains("tar -xf - -C \"$tmp\" || exit $?"))
        XCTAssertTrue(command.contains("mv \"$tmp/$src_base\" \"$dest\""))
    }

    func testBuildsRemoteDirectoryDownloadCommandUsingTarStream() throws {
        let ctx = try RuntimeManagerCopyTestContext.make()
        defer { ctx.cleanup() }

        let manager = try RuntimeManager(executablePath: "/usr/bin/true", fileManager: .default)
        let command = manager.makeRemoteDirectoryDownloadCommand(remotePath: "/var/log")

        XCTAssertTrue(command.contains("src='/var/log'"))
        XCTAssertTrue(command.contains("if [ ! -d \"$src\" ]"))
        XCTAssertTrue(command.contains("exec tar -cf - -C \"$parent\" \"$base\""))
    }

    func testBuildsRemoteDirectoryDownloadCommandForGuestHomePath() throws {
        let ctx = try RuntimeManagerCopyTestContext.make()
        defer { ctx.cleanup() }

        let manager = try RuntimeManager(executablePath: "/usr/bin/true", fileManager: .default)
        let command = manager.makeRemoteDirectoryDownloadCommand(remotePath: "~")

        XCTAssertTrue(command.contains("src=\"$HOME\""))
    }

    func testBuildsRemoteDirectoryDownloadCommandForGuestRelativePathUnderHome() throws {
        let ctx = try RuntimeManagerCopyTestContext.make()
        defer { ctx.cleanup() }

        let manager = try RuntimeManager(executablePath: "/usr/bin/true", fileManager: .default)
        let command = manager.makeRemoteDirectoryDownloadCommand(remotePath: "logs")

        XCTAssertTrue(command.contains("src=\"$HOME\"/'logs'"))
    }

    func testResolvesLocalFileDownloadTargetInsideExistingDirectory() throws {
        let ctx = try RuntimeManagerCopyTestContext.make()
        defer { ctx.cleanup() }

        let downloadDir = ctx.root.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)

        let manager = try RuntimeManager(executablePath: "/usr/bin/true", fileManager: .default)
        let target = try manager.resolveLocalFileDownloadTarget(
            remotePath: "/var/log/syslog",
            localPath: downloadDir.path
        )

        XCTAssertEqual(target.path, downloadDir.appendingPathComponent("syslog", isDirectory: false).path)
    }

    func testExpandsLocalCopyPathForHomeShortcut() throws {
        let ctx = try RuntimeManagerCopyTestContext.make()
        defer { ctx.cleanup() }

        let manager = try RuntimeManager(executablePath: "/usr/bin/true", fileManager: .default)
        let expanded = try manager.expandLocalCopyPath("~/downloads/file.txt")

        XCTAssertEqual(expanded, ("~/downloads/file.txt" as NSString).expandingTildeInPath)
    }

    func testResolvesLocalFileDownloadTargetWithHomeShortcut() throws {
        let ctx = try RuntimeManagerCopyTestContext.make()
        defer { ctx.cleanup() }

        let manager = try RuntimeManager(executablePath: "/usr/bin/true", fileManager: .default)
        let target = try manager.resolveLocalFileDownloadTarget(
            remotePath: "/var/log/syslog",
            localPath: "~"
        )

        XCTAssertEqual(target.path, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("syslog", isDirectory: false).path)
    }
}

private struct RuntimeManagerCopyTestContext {
    let root: URL
    let previousMSLHome: String?
    let previousHome: String?

    static func make() throws -> RuntimeManagerCopyTestContext {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-runtime-copy-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previous = ProcessInfo.processInfo.environment["MSL_HOME"]
        let previousHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("MSL_HOME", root.path, 1)
        setenv("HOME", root.path, 1)
        return RuntimeManagerCopyTestContext(root: root, previousMSLHome: previous, previousHome: previousHome)
    }

    func cleanup() {
        if let previousMSLHome {
            setenv("MSL_HOME", previousMSLHome, 1)
        } else {
            unsetenv("MSL_HOME")
        }
        if let previousHome {
            setenv("HOME", previousHome, 1)
        } else {
            unsetenv("HOME")
        }
        try? FileManager.default.removeItem(at: root)
    }
}
