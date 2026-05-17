import XCTest
@testable import mslCore

final class CLIIntegrationManagerTests: XCTestCase {
    func testInstallCreatesManagedSymlinkDockerShimAndZprofileOnce() throws {
        let ctx = try CLIIntegrationContext.make()
        defer { ctx.cleanup() }
        let manager = ctx.makeManager()

        try manager.install(includeDockerShim: true)
        try manager.install(includeDockerShim: true)

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: manager.cliSymlinkURL.path), ctx.cli.path)
        XCTAssertTrue(try String(contentsOf: manager.dockerShimURL).contains("Managed by MSL"))
        let zprofile = try String(contentsOf: manager.zprofileURL)
        XCTAssertEqual(zprofile.components(separatedBy: CLIIntegrationManager.zprofileManagedBlock).count - 1, 1)
    }

    func testInstallDoesNotOverwriteForeignDocker() throws {
        let ctx = try CLIIntegrationContext.make()
        defer { ctx.cleanup() }
        let manager = ctx.makeManager()
        try FileManager.default.createDirectory(at: manager.localBinURL, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: manager.dockerShimURL)

        XCTAssertThrowsError(try manager.install(includeDockerShim: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.cliSymlinkURL.path))
    }

    func testUninstallRemovesOnlyManagedFilesAndBlock() throws {
        let ctx = try CLIIntegrationContext.make()
        defer { ctx.cleanup() }
        let manager = ctx.makeManager()
        try manager.install(includeDockerShim: true)
        try manager.uninstall()

        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.cliSymlinkURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.dockerShimURL.path))
        XCTAssertFalse((try String(contentsOf: manager.zprofileURL)).contains(CLIIntegrationManager.zprofileManagedBlock))
    }

    func testDockerShimCanBeManagedAfterCLIInstall() throws {
        let ctx = try CLIIntegrationContext.make()
        defer { ctx.cleanup() }
        let manager = ctx.makeManager()

        try manager.install(includeDockerShim: false)
        XCTAssertFalse(manager.status().dockerShimInstalled)

        try manager.setDockerShimInstalled(true)
        XCTAssertTrue(manager.status().dockerShimInstalled)

        try manager.setDockerShimInstalled(false)
        XCTAssertFalse(manager.status().dockerShimInstalled)
    }

    func testDockerShimRequiresInstalledCLI() throws {
        let ctx = try CLIIntegrationContext.make()
        defer { ctx.cleanup() }
        let manager = ctx.makeManager()

        XCTAssertThrowsError(try manager.setDockerShimInstalled(true))
    }

    func testShellenvOmitsAlreadyActiveLocalBin() throws {
        let ctx = try CLIIntegrationContext.make()
        defer { ctx.cleanup() }
        XCTAssertTrue(CLIIntegrationManager.shellenv(homeDirectoryURL: ctx.root, currentPATH: "\(ctx.root.path)/.local/bin:/usr/bin").isEmpty)
        XCTAssertEqual(
            CLIIntegrationManager.shellenv(homeDirectoryURL: ctx.root, currentPATH: "/usr/bin"),
            "export PATH=\"$HOME/.local/bin:$PATH\""
        )
    }
}

private struct CLIIntegrationContext {
    let root: URL
    let cli: URL

    static func make() throws -> CLIIntegrationContext {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-cli-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cli = root.appendingPathComponent("MSL.app/Contents/MacOS/msl", isDirectory: false)
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: cli)
        return CLIIntegrationContext(root: root, cli: cli)
    }

    func makeManager() -> CLIIntegrationManager {
        CLIIntegrationManager(homeDirectoryURL: root, bundledCLIURL: cli, environment: ["PATH": "/usr/bin"])
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
