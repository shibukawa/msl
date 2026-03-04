import XCTest
@testable import mslCore

final class DistributionManagerTests: XCTestCase {
    func testManifestAliasResolution() throws {
        let entry = DistributionManifestEntry(
            id: "ubuntu-24.04-arm64",
            distro: "ubuntu",
            version: "24.04",
            arch: "arm64",
            tarballURL: "https://example.com/rootfs.tar.xz",
            sha256: "abc",
            signatureURL: "https://example.com/SHA256SUMS.gpg",
            checksumURL: "https://example.com/SHA256SUMS",
            signatureTarget: "checksum",
            keyFingerprint: "001122",
            supportState: .supported
        )
        let store = DistributionManifestStore(entries: [entry])
        XCTAssertEqual(store.resolve(alias: "ubuntu-24.04")?.id, entry.id)
        XCTAssertEqual(store.resolve(alias: "ubuntu-noble")?.id, entry.id)
        XCTAssertNil(store.resolve(alias: "alpine"))
    }

    func testManifestValidationRejectsPlaceholder() throws {
        let entry = DistributionManifestEntry(
            id: "alpine-latest-aarch64",
            distro: "alpine",
            version: "latest",
            arch: "aarch64",
            tarballURL: "https://example.com/rootfs.tar.gz",
            sha256: "REPLACE_WITH_UPDATE_COMMAND",
            signatureURL: "REPLACE_WITH_UPDATE_COMMAND",
            checksumURL: nil,
            signatureTarget: "artifact",
            keyFingerprint: "REPLACE_WITH_UPDATE_COMMAND",
            supportState: .supported
        )
        let store = DistributionManifestStore(entries: [entry])
        XCTAssertThrowsError(try store.validate(entry)) { error in
            guard let runtime = error as? MSLRuntimeError else {
                XCTFail("unexpected error type: \(error)")
                return
            }
            XCTAssertTrue(runtime.message.contains("not finalized"))
        }
    }

    func testTarEntryPathSafety() {
        XCTAssertTrue(DistributionManager.isSafeTarEntryPath("etc/passwd"))
        XCTAssertTrue(DistributionManager.isSafeTarEntryPath("./usr/bin/bash"))
        XCTAssertFalse(DistributionManager.isSafeTarEntryPath("/etc/passwd"))
        XCTAssertFalse(DistributionManager.isSafeTarEntryPath("../etc/passwd"))
        XCTAssertFalse(DistributionManager.isSafeTarEntryPath("var/../etc/passwd"))
    }

    func testStageInitBinaryCreatesGuestMSLSymlink() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        let fakeInit = ctx.root.appendingPathComponent("msl-init-fake", isDirectory: false)
        try Data(repeating: 0x41, count: 64).write(to: fakeInit)
        setenv("MSL_INIT_BINARY_PATH", fakeInit.path, 1)
        defer { unsetenv("MSL_INIT_BINARY_PATH") }

        let rootfs = ctx.root.appendingPathComponent("rootfs", isDirectory: true)
        try FileManager.default.createDirectory(at: rootfs, withIntermediateDirectories: true)

        let manager = ctx.makeManager()
        try manager.stageInitBinary(intoRootfs: rootfs)

        let initInUsrLocal = rootfs.appendingPathComponent("usr/local/bin/msl-init", isDirectory: false)
        let guestMSL = rootfs.appendingPathComponent("usr/local/bin/msl", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: initInUsrLocal.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: guestMSL.path))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: guestMSL.path),
            "msl-init"
        )
    }

    func testParseSHA256FromChecksumFile() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        let checksum = ctx.root.appendingPathComponent("SHA256SUMS", isDirectory: false)
        try """
        0123456789abcdef  ubuntu-24.04-minimal-cloudimg-arm64-root.tar.xz
        deadbeefdeadbeef  other.tar.xz
        """.write(to: checksum, atomically: true, encoding: .utf8)

        let manager = ctx.makeManager()
        let got = try manager.parseSHA256FromChecksumFile(
            checksum,
            fileName: "ubuntu-24.04-minimal-cloudimg-arm64-root.tar.xz"
        )
        XCTAssertEqual(got, "0123456789abcdef")
    }

    func testResolveSourceWithLocalFile() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        let tar = ctx.root.appendingPathComponent("rootfs.tar.xz", isDirectory: false)
        try Data([0x00]).write(to: tar)
        let source = try ctx.makeManager().resolveSource(
            targetAlias: nil,
            localFilePath: tar.path
        )

        switch source {
        case .localFile(let resolved):
            XCTAssertEqual(resolved.path, tar.path)
        default:
            XCTFail("expected localFile source")
        }
    }

    func testInstallableNames() {
        let entries = [
            DistributionManifestEntry(
                id: "alpine-latest-aarch64",
                distro: "alpine",
                version: "latest",
                arch: "aarch64",
                tarballURL: "https://example.com/alpine.tar.gz",
                sha256: "a",
                signatureURL: "https://example.com/alpine.sig",
                checksumURL: "https://example.com/alpine.sha256",
                signatureTarget: "artifact",
                keyFingerprint: "F1",
                supportState: .supported
            ),
            DistributionManifestEntry(
                id: "ubuntu-24.04-arm64",
                distro: "ubuntu",
                version: "24.04",
                arch: "arm64",
                tarballURL: "https://example.com/u2404.tar.xz",
                sha256: "b",
                signatureURL: "https://example.com/u2404.sig",
                checksumURL: "https://example.com/u2404.sha256",
                signatureTarget: "checksum",
                keyFingerprint: "F2",
                supportState: .supported
            ),
            DistributionManifestEntry(
                id: "ubuntu-25.10-arm64",
                distro: "ubuntu",
                version: "25.10",
                arch: "arm64",
                tarballURL: "https://example.com/u2510.tar.xz",
                sha256: "c",
                signatureURL: "https://example.com/u2510.sig",
                checksumURL: "https://example.com/u2510.sha256",
                signatureTarget: "checksum",
                keyFingerprint: "F3",
                supportState: .supported
            )
        ]
        let store = DistributionManifestStore(entries: entries)
        XCTAssertEqual(store.installableNames(), ["alpine", "ubuntu-24.04", "ubuntu-25.10"])
    }

    func testInstallableDescriptorsExposeAliases() {
        let entry = DistributionManifestEntry(
            id: "ubuntu-24.04-arm64",
            distro: "ubuntu",
            version: "24.04",
            arch: "arm64",
            tarballURL: "https://example.com/u2404.tar.xz",
            sha256: "b",
            signatureURL: "https://example.com/u2404.sig",
            checksumURL: "https://example.com/u2404.sha256",
            signatureTarget: "checksum",
            keyFingerprint: "F2",
            supportState: .supported
        )
        let descriptor = DistributionInstallDescriptor(
            canonicalName: "ubuntu-24.04",
            aliases: ["ubuntu", "ubuntu-lts"],
            manifestId: entry.id
        )
        let store = DistributionManifestStore(entries: [entry], installDescriptors: [descriptor])
        XCTAssertEqual(store.resolve(alias: "ubuntu")?.id, entry.id)
        XCTAssertEqual(store.resolve(alias: "ubuntu-lts")?.id, entry.id)
        XCTAssertEqual(store.installableDescriptors(), [descriptor])
    }

    func testInstallCatalogContainsUbuntuQuestingAlias() {
        let descriptor = EmbeddedDistributionInstallCatalog.descriptors
            .first { $0.canonicalName == "ubuntu-25.10" }
        XCTAssertNotNil(descriptor)
        XCTAssertTrue(descriptor?.aliases.contains("ubuntu-questing") == true)
    }

    func testRuntimeMetadataURLPrefersConfiguredDefaultInstance() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        try ctx.makeInstance(name: "dev")
        try ctx.makeInstance(name: "ci")

        let url = try ctx.makeManager().runtimeMetadataURL(defaultInstanceName: "dev")
        XCTAssertEqual(url.path, ctx.paths.distroMetadataFile(named: "dev").path)
    }

    func testRuntimeMetadataURLFallsBackToFirstInstalledInstance() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        try ctx.makeInstance(name: "default")
        try ctx.makeInstance(name: "alpine")
        try ctx.makeInstance(name: "ubuntu")

        let url = try ctx.makeManager().runtimeMetadataURL(defaultInstanceName: nil)
        XCTAssertEqual(url.path, ctx.paths.distroMetadataFile(named: "alpine").path)
    }

    func testRuntimeMetadataURLUsesExplicitInstanceFirst() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        try ctx.makeInstance(name: "dev")
        try ctx.makeInstance(name: "ci")

        let url = try ctx.makeManager().runtimeMetadataURL(
            explicitInstanceName: "ci",
            defaultInstanceName: "dev"
        )
        XCTAssertEqual(url.path, ctx.paths.distroMetadataFile(named: "ci").path)
    }

    func testReadOrRebuildInstanceMetadataBackfillsCacheSharingPolicy() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        let name = "alpine"
        let instanceDir = ctx.paths.distroDirectory(named: name)
        try FileManager.default.createDirectory(at: instanceDir, withIntermediateDirectories: true)
        let disk = ctx.paths.distroDiskFile(named: name)
        try Data([0x00]).write(to: disk)

        let metadata = DistributionInstanceMetadata(
            name: name,
            distroFamily: "alpine",
            createdAtEpochMs: nowEpochMs(),
            source: DistributionSourceRecord(
                sourceType: "manifest",
                distro: "alpine",
                version: "latest",
                arch: "aarch64",
                manifestId: "alpine-latest-aarch64",
                localPath: nil,
                tarballFileName: "rootfs.tar.gz",
                sha256: "abc",
                verifiedAtEpochMs: nowEpochMs()
            ),
            diskPath: disk.path,
            kernelProfileRef: nil,
            userConvergencePolicy: nil
        )
        let metadataURL = ctx.paths.distroMetadataFile(named: name)
        try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)

        let loaded = try ctx.makeManager().readOrRebuildInstanceMetadata(at: metadataURL)
        XCTAssertEqual(loaded.cacheSharing?.enabled, true)
        XCTAssertEqual(loaded.cacheSharing?.apt, false)
        XCTAssertEqual(loaded.cacheSharing?.apk, true)
    }

    func testRuntimeMetadataURLFailsForMissingExplicitInstance() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        try ctx.makeInstance(name: "dev")

        XCTAssertThrowsError(try ctx.makeManager().runtimeMetadataURL(
            explicitInstanceName: "missing",
            defaultInstanceName: "dev"
        )) { error in
            guard let runtime = error as? MSLRuntimeError else {
                XCTFail("unexpected error type: \(error)")
                return
            }
            XCTAssertTrue(runtime.message.contains("instance 'missing' not found"))
        }
    }

    func testInstalledInstancesExcludesLegacyDefaultInstance() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        try ctx.makeInstance(name: "default")
        try ctx.makeInstance(name: "alpine")

        let names = ctx.makeManager()
            .installedInstances()
            .map(\.name)
        XCTAssertEqual(names, ["alpine"])
    }

    func testRuntimeMetadataURLErrorsWhenNoBootableInstanceExists() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        XCTAssertThrowsError(try ctx.makeManager().runtimeMetadataURL(defaultInstanceName: "missing")) { error in
            guard let runtime = error as? MSLRuntimeError else {
                XCTFail("unexpected error type: \(error)")
                return
            }
            XCTAssertTrue(runtime.message.contains("no bootable instance found"))
        }
    }

    func testResolveExt4HelperExecutablePrefersEnvironmentOverride() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        let helper = ctx.root
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("msl-ext4-image", isDirectory: false)
        try ctx.makeExecutable(at: helper)

        setenv("MSL_EXT4_HELPER_PATH", helper.path, 1)
        defer { unsetenv("MSL_EXT4_HELPER_PATH") }

        let got = ctx.makeManager().resolveExt4HelperExecutable()
        XCTAssertEqual(got, helper.path)
    }

    func testResolveExt4HelperExecutableUsesStagedBinary() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        unsetenv("MSL_EXT4_HELPER_PATH")
        try ctx.makeExecutable(at: ctx.paths.mslHostExt4HelperBinaryFile)

        let got = ctx.makeManager().resolveExt4HelperExecutable()
        XCTAssertEqual(got, ctx.paths.mslHostExt4HelperBinaryFile.path)
    }

    func testResolveExt4MkfsHelperExecutableUsesStagedBinary() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        unsetenv("MSL_EXT4_MKFS_HELPER_PATH")
        try ctx.makeExecutable(at: ctx.paths.mslHostExt4MkfsHelperBinaryFile)

        let got = ctx.makeManager().resolveExt4MkfsHelperExecutable()
        XCTAssertEqual(got, ctx.paths.mslHostExt4MkfsHelperBinaryFile.path)
    }

    func testCreateImageWithImagewriterReportsStageHintFromExitCode() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        let localTarball = ctx.root.appendingPathComponent("rootfs.tar.gz", isDirectory: false)
        try Data("not-a-real-tarball".utf8).write(to: localTarball)

        let fakeInit = ctx.root.appendingPathComponent("msl-init-fake", isDirectory: false)
        try Data(repeating: 0x42, count: 64).write(to: fakeInit)
        setenv("MSL_INIT_BINARY_PATH", fakeInit.path, 1)
        defer { unsetenv("MSL_INIT_BINARY_PATH") }

        let fakeImagewriter = ctx.root.appendingPathComponent("imagewriter-fail.sh", isDirectory: false)
        try Data("#!/bin/sh\nexit 22\n".utf8).write(to: fakeImagewriter)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeImagewriter.path)
        setenv("MSL_IMAGEWRITER_BUILD_SCRIPT", fakeImagewriter.path, 1)
        defer { unsetenv("MSL_IMAGEWRITER_BUILD_SCRIPT") }

        let manager = ctx.makeManager()
        XCTAssertThrowsError(try manager.createImageWithImagewriter(
            name: "dev",
            targetAlias: nil,
            localFilePath: localTarball.path,
            rebuild: false,
            diskSizeGB: nil,
            mslExecutablePath: "/usr/bin/true"
        )) { error in
            guard let runtime = error as? MSLRuntimeError else {
                return XCTFail("unexpected error type: \(error)")
            }
            XCTAssertTrue(runtime.message.contains("stage=btrfs_build"))
        }
    }

    func testUninstallInstanceRemovesManifestCacheByDefault() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        try ctx.makeInstance(name: "dev")
        let cacheDir = ctx.paths.cacheDownloadsDir
            .appendingPathComponent("ubuntu", isDirectory: true)
            .appendingPathComponent("24.04", isDirectory: true)
            .appendingPathComponent("arm64", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try Data([0x01]).write(to: cacheDir.appendingPathComponent("verified.json"))

        let result = try ctx.makeManager().uninstallInstance(name: "dev", keepCache: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ctx.paths.distroDirectory(named: "dev").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheDir.path))
        XCTAssertEqual(result.removedCachePath, cacheDir.path)
    }

    func testUninstallInstanceKeepsCacheWithFlag() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        try ctx.makeInstance(name: "dev")
        let cacheDir = ctx.paths.cacheDownloadsDir
            .appendingPathComponent("ubuntu", isDirectory: true)
            .appendingPathComponent("24.04", isDirectory: true)
            .appendingPathComponent("arm64", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try Data([0x01]).write(to: cacheDir.appendingPathComponent("verified.json"))

        let result = try ctx.makeManager().uninstallInstance(name: "dev", keepCache: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ctx.paths.distroDirectory(named: "dev").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheDir.path))
        XCTAssertEqual(result.keptCachePath, cacheDir.path)
    }

    func testResolveUserConvergencePolicyBackfillsFromManifestTemplate() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        let template = UserConvergencePolicyTemplate(
            templateId: "test-template",
            commandFamily: "busybox_adduser",
            adminGroup: "wheel",
            sudoPolicy: SudoPolicyTemplate(
                enabled: true,
                requireSudoBinary: false,
                dropInPath: "/etc/sudoers.d/msl-user"
            ),
            suPolicy: SuPolicyTemplate(
                enabled: true,
                passwordless: true
            ),
            shellFallbacks: ["/bin/ash", "/bin/sh"],
            welcomePolicy: WelcomePolicyTemplate(
                enabled: true,
                frequency: "daily",
                respectHushlogin: true
            )
        )
        let entry = DistributionManifestEntry(
            id: "custom-manifest",
            distro: "alpine",
            version: "latest",
            arch: "aarch64",
            tarballURL: "https://example.com/alpine.tar.gz",
            sha256: "abc",
            signatureURL: "https://example.com/alpine.sig",
            checksumURL: "https://example.com/alpine.sha256",
            signatureTarget: "artifact",
            keyFingerprint: "F1",
            supportState: .supported,
            userConvergenceTemplate: template
        )
        let store = DistributionManifestStore(entries: [entry])
        let logger = MSLLogger(logFile: ctx.paths.logs.appendingPathComponent("test.log", isDirectory: false))
        let manager = DistributionManager(paths: ctx.paths, logger: logger, manifestStore: store)

        let name = "dev"
        let instanceDir = ctx.paths.distroDirectory(named: name)
        try FileManager.default.createDirectory(at: instanceDir, withIntermediateDirectories: true)
        let disk = ctx.paths.distroDiskFile(named: name)
        try Data([0x00]).write(to: disk)
        let metadata = DistributionInstanceMetadata(
            name: name,
            createdAtEpochMs: nowEpochMs(),
            source: DistributionSourceRecord(
                sourceType: "manifest",
                distro: "alpine",
                version: "latest",
                arch: "aarch64",
                manifestId: entry.id,
                localPath: nil,
                tarballFileName: "rootfs.tar.gz",
                sha256: "abc",
                verifiedAtEpochMs: nowEpochMs()
            ),
            diskPath: disk.path,
            kernelProfileRef: nil,
            userConvergencePolicy: nil
        )
        let metadataURL = ctx.paths.distroMetadataFile(named: name)
        try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)

        let policy = try manager.resolveUserConvergencePolicy(metadataURL: metadataURL)
        XCTAssertEqual(policy.templateId, "test-template")
        XCTAssertEqual(policy.commandFamily, "busybox_adduser")
        XCTAssertEqual(policy.adminGroup, "wheel")
        XCTAssertEqual(policy.suPolicy?.enabled, true)
        XCTAssertEqual(policy.suPolicy?.passwordless, true)

        let saved = try JSONDecoder().decode(
            DistributionInstanceMetadata.self,
            from: Data(contentsOf: metadataURL)
        )
        XCTAssertEqual(saved.userConvergencePolicy?.templateId, "test-template")
        XCTAssertEqual(saved.userConvergencePolicy?.suPolicy?.enabled, true)
        XCTAssertEqual(saved.userConvergencePolicy?.suPolicy?.passwordless, true)
    }

    func testResolveUserConvergencePolicyRejectsInvalidCommandFamily() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        let manager = ctx.makeManager()
        let name = "dev"
        let instanceDir = ctx.paths.distroDirectory(named: name)
        try FileManager.default.createDirectory(at: instanceDir, withIntermediateDirectories: true)
        let disk = ctx.paths.distroDiskFile(named: name)
        try Data([0x00]).write(to: disk)

        let invalidPolicy = UserConvergencePolicyTemplate(
            templateId: "invalid",
            commandFamily: "unknown",
            adminGroup: "sudo",
            sudoPolicy: SudoPolicyTemplate(),
            shellFallbacks: ["/bin/sh"],
            welcomePolicy: WelcomePolicyTemplate()
        )
        let metadata = DistributionInstanceMetadata(
            name: name,
            createdAtEpochMs: nowEpochMs(),
            source: DistributionSourceRecord(
                sourceType: "local",
                distro: nil,
                version: nil,
                arch: nil,
                manifestId: nil,
                localPath: "/tmp/rootfs.tar",
                tarballFileName: "rootfs.tar",
                sha256: "abc",
                verifiedAtEpochMs: nowEpochMs()
            ),
            diskPath: disk.path,
            kernelProfileRef: nil,
            userConvergencePolicy: invalidPolicy
        )
        let metadataURL = ctx.paths.distroMetadataFile(named: name)
        try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)

        XCTAssertThrowsError(try manager.resolveUserConvergencePolicy(metadataURL: metadataURL)) { error in
            guard let runtime = error as? MSLRuntimeError else {
                return XCTFail("unexpected error type: \(error)")
            }
            XCTAssertTrue(runtime.message.contains("commandFamily"))
        }
    }
}

private struct DistributionContext {
    let root: URL
    let paths: MSLPaths

    static func make() throws -> DistributionContext {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-distribution-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = MSLPaths(homeDirectoryURL: root)
        try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        return DistributionContext(root: root, paths: paths)
    }

    func makeManager() -> DistributionManager {
        let logger = MSLLogger(logFile: paths.logs.appendingPathComponent("test.log", isDirectory: false))
        return DistributionManager(paths: paths, logger: logger)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func makeExecutable(at path: URL) throws {
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }

    func makeInstance(name: String) throws {
        let instanceDir = paths.distroDirectory(named: name)
        try FileManager.default.createDirectory(at: instanceDir, withIntermediateDirectories: true)

        let disk = paths.distroDiskFile(named: name)
        try Data([0x00]).write(to: disk)

        let metadata = DistributionInstanceMetadata(
            name: name,
            createdAtEpochMs: nowEpochMs(),
            source: DistributionSourceRecord(
                sourceType: "manifest",
                distro: "ubuntu",
                version: "24.04",
                arch: "arm64",
                manifestId: "ubuntu-24.04-arm64",
                localPath: nil,
                tarballFileName: "rootfs.tar.xz",
                sha256: "abc",
                verifiedAtEpochMs: nowEpochMs()
            ),
            diskPath: disk.path,
            kernelProfileRef: nil,
            userConvergencePolicy: nil
        )
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: paths.distroMetadataFile(named: name), options: .atomic)
    }
}
