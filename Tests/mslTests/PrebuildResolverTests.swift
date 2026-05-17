import XCTest
@testable import mslCore

final class PrebuildResolverTests: XCTestCase {
    func testKernelDirectoryPrefersUserOverrideBeforeBundle() throws {
        let ctx = try PrebuildResolverContext.make()
        defer { ctx.cleanup() }
        try ctx.makeDirectory(ctx.paths.kernelsDir.appendingPathComponent("slim", isDirectory: true))
        try ctx.makeDirectory(ctx.bundleRoot.appendingPathComponent("prebuilds/kernels/slim", isDirectory: true))

        let resolver = PrebuildResolver(
            paths: ctx.paths,
            environment: ["MSL_BUNDLE_RESOURCES_DIR": ctx.bundleRoot.path]
        )
        XCTAssertEqual(resolver.kernelDirectory(profile: "slim")?.path, ctx.paths.kernelsDir.appendingPathComponent("slim").path)
    }

    func testKernelDirectoryFallsBackToBundle() throws {
        let ctx = try PrebuildResolverContext.make()
        defer { ctx.cleanup() }
        let bundled = ctx.bundleRoot.appendingPathComponent("prebuilds/kernels/slim", isDirectory: true)
        try ctx.makeDirectory(bundled)

        let resolver = PrebuildResolver(
            paths: ctx.paths,
            environment: ["MSL_BUNDLE_RESOURCES_DIR": ctx.bundleRoot.path]
        )
        XCTAssertEqual(resolver.kernelDirectory(profile: "slim")?.path, bundled.path)
    }

    func testGuestBinaryPrefersUserOverrideBeforeExplicitEnvironment() throws {
        let ctx = try PrebuildResolverContext.make()
        defer { ctx.cleanup() }
        let explicit = ctx.root.appendingPathComponent("explicit-msl-init", isDirectory: false)
        try ctx.makeExecutable(explicit)
        let override = ctx.paths.prebuildOverridesDir.appendingPathComponent("guest-tools/msl-init", isDirectory: false)
        try ctx.makeExecutable(override)
        try ctx.makeExecutable(ctx.bundleRoot.appendingPathComponent("prebuilds/guest-tools/msl-init", isDirectory: false))

        let resolver = PrebuildResolver(
            paths: ctx.paths,
            environment: [
                "MSL_BUNDLE_RESOURCES_DIR": ctx.bundleRoot.path,
                "MSL_INIT_BINARY_PATH": explicit.path
            ]
        )
        XCTAssertEqual(resolver.guestBinary(envVar: "MSL_INIT_BINARY_PATH", name: "msl-init")?.path, override.path)
    }

    func testContainerToolCandidatesStartWithUserOverride() throws {
        let ctx = try PrebuildResolverContext.make()
        defer { ctx.cleanup() }
        let override = ctx.paths.prebuildOverridesDir.appendingPathComponent("container-tools", isDirectory: true)
        try ctx.makeDirectory(override)
        let resolver = PrebuildResolver(
            paths: ctx.paths,
            environment: ["MSL_BUNDLE_RESOURCES_DIR": ctx.bundleRoot.path]
        )
        XCTAssertEqual(resolver.containerToolCandidateDirectories().first?.path, override.path)
    }
}

private struct PrebuildResolverContext {
    let root: URL
    let bundleRoot: URL
    let paths: MSLPaths

    static func make() throws -> PrebuildResolverContext {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-prebuild-tests-\(UUID().uuidString)", isDirectory: true)
        let bundleRoot = root.appendingPathComponent("bundle-resources", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)
        let paths = MSLPaths(homeDirectoryURL: root)
        return PrebuildResolverContext(root: root, bundleRoot: bundleRoot, paths: paths)
    }

    func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func makeExecutable(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data("tool".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
