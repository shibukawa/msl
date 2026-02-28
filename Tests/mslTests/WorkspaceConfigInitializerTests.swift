import XCTest
@testable import mslCore

final class WorkspaceConfigInitializerTests: XCTestCase {
    func testCreateConfigWritesTemplate() throws {
        let ctx = try WorkspaceConfigContext.make()
        defer { ctx.cleanup() }

        let initializer = WorkspaceConfigInitializer(fileManager: .default)
        let result = try initializer.createConfig(in: ctx.workspace, force: false)

        XCTAssertFalse(result.overwritten)
        XCTAssertEqual(result.configFile.path, ctx.workspace.appendingPathComponent(".mslconfig").path)
        let content = try String(contentsOf: result.configFile, encoding: .utf8)
        XCTAssertTrue(content.contains("[workspace.excludes]"))
        XCTAssertTrue(content.contains("node_modules"))
    }

    func testCreateConfigFailsWhenAlreadyExistsWithoutForce() throws {
        let ctx = try WorkspaceConfigContext.make()
        defer { ctx.cleanup() }

        let configFile = ctx.workspace.appendingPathComponent(".mslconfig", isDirectory: false)
        try Data("old\n".utf8).write(to: configFile, options: .atomic)

        let initializer = WorkspaceConfigInitializer(fileManager: .default)
        XCTAssertThrowsError(
            try initializer.createConfig(in: ctx.workspace, force: false)
        ) { error in
            guard let runtime = error as? MSLRuntimeError else {
                XCTFail("unexpected error: \(error)")
                return
            }
            XCTAssertTrue(runtime.message.contains(".mslconfig already exists"))
        }
    }

    func testCreateConfigOverwritesWhenForceEnabled() throws {
        let ctx = try WorkspaceConfigContext.make()
        defer { ctx.cleanup() }

        let configFile = ctx.workspace.appendingPathComponent(".mslconfig", isDirectory: false)
        try Data("old\n".utf8).write(to: configFile, options: .atomic)

        let initializer = WorkspaceConfigInitializer(fileManager: .default)
        let result = try initializer.createConfig(in: ctx.workspace, force: true)

        XCTAssertTrue(result.overwritten)
        let content = try String(contentsOf: configFile, encoding: .utf8)
        XCTAssertTrue(content.contains("[workspace.excludes]"))
        XCTAssertFalse(content.hasPrefix("old"))
    }
}

private struct WorkspaceConfigContext {
    let root: URL
    let workspace: URL

    static func make() throws -> WorkspaceConfigContext {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-workspace-config-tests-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return WorkspaceConfigContext(root: root, workspace: workspace)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
