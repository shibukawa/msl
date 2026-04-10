import XCTest
@testable import mslCore

final class RuntimeBootProfileResolverTests: XCTestCase {
    func testResolvesKernelProfileWithEnvPriority() throws {
        let ctx = try RuntimeBootProfileResolverContext.make()
        defer { ctx.cleanup() }

        try ctx.writeMetadata(instanceName: "dev", kernelProfileRef: "meta-kernel")
        try ctx.makeKernelProfile("env-kernel")
        try ctx.makeKernelProfile("meta-kernel")

        let resolver = RuntimeBootProfileResolver(
            paths: ctx.paths,
            logger: nil,
            environment: ["MSL_KERNEL_PROFILE": "env-kernel"]
        )

        let profile = try resolver.resolve(
            metadataURL: ctx.metadataURL(instanceName: "dev"),
            instanceName: "dev",
            defaultKernelProfileRef: "config-kernel"
        )
        XCTAssertEqual(profile.kernelID, "env-kernel")
        XCTAssertTrue(profile.kernelURL.path.hasSuffix("/env-kernel/vmlinuz"))
        XCTAssertEqual(profile.commandLine, "root=/dev/vda rw console=hvc0 init=/sbin/msl-init-bootloader")
    }

    func testResolvesKernelProfileFromMetadataBeforeConfig() throws {
        let ctx = try RuntimeBootProfileResolverContext.make()
        defer { ctx.cleanup() }

        try ctx.writeMetadata(instanceName: "dev", kernelProfileRef: "meta-kernel")
        try ctx.makeKernelProfile("meta-kernel")
        try ctx.makeKernelProfile("config-kernel")

        let resolver = RuntimeBootProfileResolver(paths: ctx.paths, logger: nil, environment: [:])
        let profile = try resolver.resolve(
            metadataURL: ctx.metadataURL(instanceName: "dev"),
            instanceName: "dev",
            defaultKernelProfileRef: "config-kernel"
        )
        XCTAssertEqual(profile.kernelID, "meta-kernel")
    }

    func testResolvesKernelProfileFromConfigWhenMetadataIsMissing() throws {
        let ctx = try RuntimeBootProfileResolverContext.make()
        defer { ctx.cleanup() }

        try ctx.writeMetadata(instanceName: "dev", kernelProfileRef: nil)
        try ctx.makeKernelProfile("config-kernel")

        let resolver = RuntimeBootProfileResolver(paths: ctx.paths, logger: nil, environment: [:])
        let profile = try resolver.resolve(
            metadataURL: ctx.metadataURL(instanceName: "dev"),
            instanceName: "dev",
            defaultKernelProfileRef: "config-kernel"
        )
        XCTAssertEqual(profile.kernelID, "config-kernel")
    }

    func testFailsWhenDefaultSlimKernelIsMissing() throws {
        let ctx = try RuntimeBootProfileResolverContext.make()
        defer { ctx.cleanup() }

        try ctx.writeMetadata(instanceName: "dev", kernelProfileRef: nil)

        let resolver = RuntimeBootProfileResolver(paths: ctx.paths, logger: nil, environment: [:])
        XCTAssertThrowsError(
            try resolver.resolve(
                metadataURL: ctx.metadataURL(instanceName: "dev"),
                instanceName: "dev",
                defaultKernelProfileRef: nil
            )
        ) { error in
            guard let runtime = error as? MSLRuntimeError else {
                XCTFail("unexpected error type: \(error)")
                return
            }
            XCTAssertTrue(runtime.message.contains("Step6 kernel not found"))
            XCTAssertTrue(runtime.message.contains("/slim/vmlinuz"))
        }
    }

    func testResolvesSlimKernelWhenUnspecified() throws {
        let ctx = try RuntimeBootProfileResolverContext.make()
        defer { ctx.cleanup() }

        try ctx.writeMetadata(instanceName: "dev", kernelProfileRef: nil)
        try ctx.makeKernelProfile("slim")
        try ctx.makeKernelProfile("other-kernel")

        let resolver = RuntimeBootProfileResolver(paths: ctx.paths, logger: nil, environment: [:])
        let profile = try resolver.resolve(
            metadataURL: ctx.metadataURL(instanceName: "dev"),
            instanceName: "dev",
            defaultKernelProfileRef: nil
        )
        XCTAssertEqual(profile.kernelID, "slim")
        XCTAssertTrue(profile.kernelURL.path.hasSuffix("/slim/vmlinuz"))
    }

    func testFailsWhenVmlinuzIsMissing() throws {
        let ctx = try RuntimeBootProfileResolverContext.make()
        defer { ctx.cleanup() }

        try ctx.writeMetadata(instanceName: "dev", kernelProfileRef: "missing-kernel")
        let kernelDir = ctx.paths.kernelsDir.appendingPathComponent("missing-kernel", isDirectory: true)
        try FileManager.default.createDirectory(at: kernelDir, withIntermediateDirectories: true)

        let resolver = RuntimeBootProfileResolver(paths: ctx.paths, logger: nil, environment: [:])
        XCTAssertThrowsError(
            try resolver.resolve(
                metadataURL: ctx.metadataURL(instanceName: "dev"),
                instanceName: "dev",
                defaultKernelProfileRef: nil
            )
        ) { error in
            guard let runtime = error as? MSLRuntimeError else {
                XCTFail("unexpected error type: \(error)")
                return
            }
            XCTAssertTrue(runtime.message.contains("Step6 kernel not found"))
            XCTAssertTrue(runtime.message.contains("/missing-kernel/vmlinuz"))
        }
    }
}

private struct RuntimeBootProfileResolverContext {
    let root: URL
    let paths: MSLPaths

    static func make() throws -> RuntimeBootProfileResolverContext {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-boot-profile-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = MSLPaths(homeDirectoryURL: root)
        try FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.distrosDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.kernelsDir, withIntermediateDirectories: true)
        return RuntimeBootProfileResolverContext(root: root, paths: paths)
    }

    func metadataURL(instanceName: String) -> URL {
        paths.distroMetadataFile(named: instanceName)
    }

    func writeMetadata(instanceName: String, kernelProfileRef: String?) throws {
        let instanceDir = paths.distroDirectory(named: instanceName)
        try FileManager.default.createDirectory(at: instanceDir, withIntermediateDirectories: true)
        let diskURL = paths.distroDiskFile(named: instanceName)
        FileManager.default.createFile(atPath: diskURL.path, contents: Data())
        let source = DistributionSourceRecord(
            sourceType: "local",
            distro: nil,
            version: nil,
            arch: nil,
            manifestId: nil,
            localPath: "/tmp/rootfs.tar",
            tarballFileName: "rootfs.tar",
            sha256: "deadbeef",
            verifiedAtEpochMs: nowEpochMs()
        )
        let metadata = DistributionInstanceMetadata(
            name: instanceName,
            createdAtEpochMs: nowEpochMs(),
            source: source,
            diskPath: diskURL.path,
            kernelProfileRef: kernelProfileRef,
            userConvergencePolicy: nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: metadataURL(instanceName: instanceName), options: .atomic)
    }

    func makeKernelProfile(_ kernelID: String) throws {
        let kernelDir = paths.kernelsDir.appendingPathComponent(kernelID, isDirectory: true)
        try FileManager.default.createDirectory(at: kernelDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: kernelDir.appendingPathComponent("vmlinuz").path, contents: Data("kernel".utf8))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
