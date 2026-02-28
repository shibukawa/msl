import XCTest
@testable import mslCore

final class WorkspaceConfigTests: XCTestCase {
    func testLoaderReturnsNilWhenConfigMissing() throws {
        let ctx = try WorkspaceConfigLoaderContext.make()
        defer { ctx.cleanup() }

        let loader = WorkspaceConfigLoader(fileManager: .default)
        let config = try loader.load(fromWorkspaceDirectory: ctx.workspace)
        XCTAssertNil(config)
    }

    func testLoaderParsesExcludePaths() throws {
        let ctx = try WorkspaceConfigLoaderContext.make()
        defer { ctx.cleanup() }

        let raw = """
        # sample
        [workspace.excludes]
        paths = ["node_modules", ".next/cache"]
        """
        try Data(raw.utf8).write(to: ctx.workspace.appendingPathComponent(".mslconfig"), options: .atomic)

        let loader = WorkspaceConfigLoader(fileManager: .default)
        let config = try loader.load(fromWorkspaceDirectory: ctx.workspace)
        XCTAssertEqual(config?.excludes, ["node_modules", ".next/cache"])
    }

    func testLoaderRejectsAbsoluteExcludePath() throws {
        let ctx = try WorkspaceConfigLoaderContext.make()
        defer { ctx.cleanup() }

        let raw = """
        [workspace.excludes]
        paths = ["/tmp/absolute"]
        """
        try Data(raw.utf8).write(to: ctx.workspace.appendingPathComponent(".mslconfig"), options: .atomic)

        let loader = WorkspaceConfigLoader(fileManager: .default)
        XCTAssertThrowsError(
            try loader.load(fromWorkspaceDirectory: ctx.workspace)
        ) { error in
            XCTAssertEqual(
                error as? WorkspaceConfigParseError,
                .invalidExcludePath(path: "/tmp/absolute", reason: "absolute paths are not allowed")
            )
        }
    }

    func testLoaderRejectsTraversalPath() throws {
        let ctx = try WorkspaceConfigLoaderContext.make()
        defer { ctx.cleanup() }

        let raw = """
        [workspace.excludes]
        paths = ["../secret"]
        """
        try Data(raw.utf8).write(to: ctx.workspace.appendingPathComponent(".mslconfig"), options: .atomic)

        let loader = WorkspaceConfigLoader(fileManager: .default)
        XCTAssertThrowsError(
            try loader.load(fromWorkspaceDirectory: ctx.workspace)
        ) { error in
            XCTAssertEqual(
                error as? WorkspaceConfigParseError,
                .invalidExcludePath(path: "../secret", reason: "dot traversal is not allowed")
            )
        }
    }

    func testExcludePlannerBuildsOverlayPaths() throws {
        let planner = WorkspaceExcludePlanner()
        let overlays = try planner.plan(
            workspaceGuestPath: "/Users/alice/work",
            excludes: ["node_modules", ".next/cache"]
        )

        XCTAssertEqual(overlays.count, 2)
        XCTAssertEqual(overlays[0].relativePath, "node_modules")
        XCTAssertEqual(overlays[0].excludedGuestPath, "/Users/alice/work/node_modules")
        XCTAssertEqual(overlays[0].overlayBackingPath, "/var/opt/msl/overlay/Users/alice/work/node_modules")
        XCTAssertEqual(overlays[1].relativePath, ".next/cache")
        XCTAssertEqual(overlays[1].excludedGuestPath, "/Users/alice/work/.next/cache")
        XCTAssertEqual(overlays[1].overlayBackingPath, "/var/opt/msl/overlay/Users/alice/work/.next/cache")
    }

    func testExcludePlannerDeduplicatesExcludedGuestPath() throws {
        let planner = WorkspaceExcludePlanner()
        let overlays = try planner.plan(
            workspaceGuestPath: "/Users/alice/work/",
            excludes: ["node_modules", "node_modules"]
        )
        XCTAssertEqual(overlays.count, 1)
    }

    func testActivationResolverDisablesWhenStartupMountDisabled() throws {
        let ctx = try WorkspaceConfigLoaderContext.make()
        defer { ctx.cleanup() }

        let raw = """
        [workspace.excludes]
        paths = ["node_modules"]
        """
        try Data(raw.utf8).write(to: ctx.workspace.appendingPathComponent(".mslconfig"), options: .atomic)

        let resolver = WorkspaceActivationResolver(fileManager: .default)
        let state = try resolver.resolve(
            launchDirectory: ctx.workspace,
            workspacePolicy: WorkspacePolicy(activationMode: "mslconfig_presence_only", startupMountEnabled: false)
        )
        XCTAssertEqual(state, .disabled(reason: "startup_mount_disabled"))
    }

    func testActivationResolverDisablesWhenConfigMissing() throws {
        let ctx = try WorkspaceConfigLoaderContext.make()
        defer { ctx.cleanup() }

        let resolver = WorkspaceActivationResolver(fileManager: .default)
        let state = try resolver.resolve(
            launchDirectory: ctx.workspace,
            workspacePolicy: WorkspacePolicy(activationMode: "mslconfig_presence_only", startupMountEnabled: true)
        )
        XCTAssertEqual(state, .disabled(reason: "workspace_config_missing"))
    }

    func testActivationResolverEnablesWhenConfigExists() throws {
        let ctx = try WorkspaceConfigLoaderContext.make()
        defer { ctx.cleanup() }

        let raw = """
        [workspace.excludes]
        paths = ["node_modules"]
        """
        try Data(raw.utf8).write(to: ctx.workspace.appendingPathComponent(".mslconfig"), options: .atomic)

        let resolver = WorkspaceActivationResolver(fileManager: .default)
        let state = try resolver.resolve(
            launchDirectory: ctx.workspace,
            workspacePolicy: WorkspacePolicy(activationMode: "mslconfig_presence_only", startupMountEnabled: true)
        )
        let expectedPath = try WorkspaceExcludePlanner.normalizedWorkspaceGuestPath(
            ctx.workspace.resolvingSymlinksInPath().path
        )
        XCTAssertEqual(
            state,
            .enabled(config: WorkspaceConfig(excludes: ["node_modules"]), workspaceGuestPath: expectedPath)
        )
    }

    func testActivationResolverDisablesForProtectedPathPrefix() throws {
        let ctx = try WorkspaceConfigLoaderContext.make()
        defer { ctx.cleanup() }

        let raw = """
        [workspace.excludes]
        paths = ["node_modules"]
        """
        try Data(raw.utf8).write(to: ctx.workspace.appendingPathComponent(".mslconfig"), options: .atomic)

        let resolver = WorkspaceActivationResolver(fileManager: .default)
        let state = try resolver.resolve(
            launchDirectory: ctx.workspace,
            workspacePolicy: WorkspacePolicy(
                activationMode: "mslconfig_presence_only",
                startupMountEnabled: true,
                protectedGuestPathPrefixes: [ctx.workspace.resolvingSymlinksInPath().path]
            )
        )
        XCTAssertEqual(state, .disabled(reason: "workspace_protected_path"))
    }
}

private struct WorkspaceConfigLoaderContext {
    let root: URL
    let workspace: URL

    static func make() throws -> WorkspaceConfigLoaderContext {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-workspace-config-loader-tests-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return WorkspaceConfigLoaderContext(root: root, workspace: workspace)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
