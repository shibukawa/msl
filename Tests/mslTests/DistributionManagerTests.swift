import XCTest
import CryptoKit
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
        let descriptor = DistributionInstallDescriptor(
            canonicalName: "ubuntu-24.04",
            aliases: ["ubuntu", "ubuntu-24.04"],
            manifestId: entry.id
        )
        let store = DistributionManifestStore(entries: [entry], installDescriptors: [descriptor])
        XCTAssertEqual(store.resolve(alias: "ubuntu-24.04")?.id, entry.id)
        XCTAssertEqual(store.resolve(alias: "ubuntu")?.id, entry.id)
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

    func testInstallableDistributionsExcludeInternalContainerRuntime() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }
        let manager = ctx.makeManager()
        XCTAssertFalse(manager.installableDistributionNames().contains("container-runtime"))
    }

    func testResolveSourceRejectsInternalContainerRuntimeWithoutAllowFlag() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        XCTAssertThrowsError(try ctx.makeManager().resolveSource(targetAlias: "container-runtime", localFilePath: nil)) { error in
            guard let runtime = error as? MSLRuntimeError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(runtime.message.contains("make build-container-runtime"))
        }
    }

    func testResolveSourceSupportsSyntheticContainerRuntimeWhenAllowFlagIsSet() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        let manager = DistributionManager(
            paths: ctx.paths,
            logger: MSLLogger(logFile: ctx.paths.logs.appendingPathComponent("test.log", isDirectory: false)),
            environment: ["MSL_ALLOW_INTERNAL_CONTAINER_RUNTIME": "1"]
        )
        let source = try manager.resolveSource(targetAlias: "container-runtime", localFilePath: nil)
        switch source {
        case .containerRuntime:
            break
        default:
            XCTFail("expected synthetic container-runtime source")
        }
    }

    func testTarEntryPathSafety() {
        XCTAssertTrue(DistributionManager.isSafeTarEntryPath("etc/passwd"))
        XCTAssertTrue(DistributionManager.isSafeTarEntryPath("./usr/bin/bash"))
        XCTAssertFalse(DistributionManager.isSafeTarEntryPath("/etc/passwd"))
        XCTAssertFalse(DistributionManager.isSafeTarEntryPath("../etc/passwd"))
        XCTAssertFalse(DistributionManager.isSafeTarEntryPath("var/../etc/passwd"))
    }

    func testResolveBundledContainerToolExtractsIntoVersionedHostDirectory() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        let bundleDir = ctx.root.appendingPathComponent("bundle-tools", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        let regctl = bundleDir.appendingPathComponent("regctl", isDirectory: false)
        try ctx.makeShellScript(at: regctl, contents: "#!/bin/sh\nexit 0\n")
        try ctx.writeBundledToolManifest(
            at: bundleDir.appendingPathComponent("manifest.json", isDirectory: false),
            bundleVersion: "bundle-v1",
            toolURLs: ["regctl": regctl]
        )

        let manager = DistributionManager(
            paths: ctx.paths,
            logger: MSLLogger(logFile: ctx.paths.logs.appendingPathComponent("test.log", isDirectory: false)),
            environment: ["MSL_BUNDLED_CONTAINER_TOOLS_DIR": bundleDir.path]
        )

        let resolved = try manager.resolveBundledOrInstalledContainerTool("regctl")
        XCTAssertEqual(resolved, ctx.paths.bundledContainerToolsDirectory(bundleVersion: "bundle-v1").appendingPathComponent("regctl", isDirectory: false).path)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: resolved))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ctx.paths.bundledContainerToolsManifestFile(bundleVersion: "bundle-v1").path))
    }

    func testResolveBundledContainerToolUsesAppSupportStagingDirectory() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        try FileManager.default.createDirectory(at: ctx.paths.bundledContainerToolsStageDir, withIntermediateDirectories: true)
        let regctl = ctx.paths.bundledContainerToolsStageDir.appendingPathComponent("regctl", isDirectory: false)
        try ctx.makeShellScript(at: regctl, contents: "#!/bin/sh\nexit 0\n")
        try ctx.writeBundledToolManifest(
            at: ctx.paths.bundledContainerToolsStageDir.appendingPathComponent("manifest.json", isDirectory: false),
            bundleVersion: "bundle-stage",
            toolURLs: ["regctl": regctl]
        )

        let manager = ctx.makeManager()
        XCTAssertEqual(try manager.resolveBundledOrInstalledContainerTool("regctl"), regctl.path)
    }

    func testResolveBundledContainerToolRejectsChecksumMismatch() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        let bundleDir = ctx.root.appendingPathComponent("bundle-tools", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        let regctl = bundleDir.appendingPathComponent("regctl", isDirectory: false)
        try ctx.makeShellScript(at: regctl, contents: "#!/bin/sh\nexit 0\n")
        let manifest = BundledToolManifest(
            bundleVersion: "bundle-bad",
            generatedAtEpochMs: 100,
            tools: [
                BundledToolRecord(
                    name: "regctl",
                    platform: "darwin-arm64",
                    version: "v0.11.2",
                    checksum: "deadbeef",
                    relativePath: "regctl"
                )
            ]
        )
        try JSONEncoder().encode(manifest).write(
            to: bundleDir.appendingPathComponent("manifest.json", isDirectory: false),
            options: .atomic
        )

        let manager = DistributionManager(
            paths: ctx.paths,
            logger: MSLLogger(logFile: ctx.paths.logs.appendingPathComponent("test.log", isDirectory: false)),
            environment: ["MSL_BUNDLED_CONTAINER_TOOLS_DIR": bundleDir.path]
        )

        XCTAssertThrowsError(try manager.resolveBundledOrInstalledContainerTool("regctl")) { error in
            guard let runtime = error as? MSLRuntimeError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(runtime.message.contains("bundled helper checksum mismatch"))
        }
    }

    func testResolveBundledContainerToolFallsBackToPATH() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        let binDir = ctx.root.appendingPathComponent("bin", isDirectory: true)
        let helper = binDir.appendingPathComponent("regctl", isDirectory: false)
        try ctx.makeShellScript(at: helper, contents: "#!/bin/sh\nexit 0\n")

        let previousPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", "\(binDir.path):\(previousPath)", 1)
        defer { setenv("PATH", previousPath, 1) }

        let manager = DistributionManager(
            paths: ctx.paths,
            logger: MSLLogger(logFile: ctx.paths.logs.appendingPathComponent("test.log", isDirectory: false))
        )
        XCTAssertEqual(try manager.resolveBundledOrInstalledContainerTool("regctl"), helper.path)
    }

    func testNormalizeContainerRootFSPermissionsAddsOwnerReadToUnreadableRegularFile() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        let rootfs = ctx.root.appendingPathComponent("container-rootfs", isDirectory: true)
        let binDir = rootfs.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let file = binDir.appendingPathComponent("bbsuid", isDirectory: false)
        try Data("binary".utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o111], ofItemAtPath: file.path)

        let manager = ctx.makeManager()
        try manager.normalizeContainerRootFSPermissions(rootfsDir: rootfs)

        let mode = try ctx.fileMode(at: file)
        XCTAssertEqual(mode, 0o511)
    }

    func testNormalizeContainerRootFSPermissionsPreservesSetuidBit() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        let rootfs = ctx.root.appendingPathComponent("container-rootfs", isDirectory: true)
        let binDir = rootfs.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let file = binDir.appendingPathComponent("suid-tool", isDirectory: false)
        try Data("binary".utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o4111], ofItemAtPath: file.path)

        let manager = ctx.makeManager()
        try manager.normalizeContainerRootFSPermissions(rootfsDir: rootfs)

        let mode = try ctx.fileMode(at: file)
        XCTAssertEqual(mode, 0o4511)
    }

    func testNormalizeContainerRootFSPermissionsLeavesSymlinkUnchanged() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        let rootfs = ctx.root.appendingPathComponent("container-rootfs", isDirectory: true)
        let binDir = rootfs.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let target = binDir.appendingPathComponent("bbsuid", isDirectory: false)
        try Data("binary".utf8).write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o111], ofItemAtPath: target.path)
        let link = binDir.appendingPathComponent("mount", isDirectory: false)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/bin/bbsuid")

        let manager = ctx.makeManager()
        try manager.normalizeContainerRootFSPermissions(rootfsDir: rootfs)

        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        XCTAssertEqual(destination, "/bin/bbsuid")
        XCTAssertEqual(try ctx.fileMode(at: target), 0o511)
    }

    func testNormalizeContainerRootFSPermissionsLeavesDirectoriesUnchanged() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        let rootfs = ctx.root.appendingPathComponent("container-rootfs", isDirectory: true)
        let dir = rootfs.appendingPathComponent("secure-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o711], ofItemAtPath: dir.path)

        let manager = ctx.makeManager()
        try manager.normalizeContainerRootFSPermissions(rootfsDir: rootfs)

        XCTAssertEqual(try ctx.fileMode(at: dir), 0o711)
    }

    func testStageInitBinaryStagesBootloaderOnly() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        let fakeInit = ctx.root.appendingPathComponent("msl-init-bootloader-fake", isDirectory: false)
        try Data(repeating: 0x41, count: 64).write(to: fakeInit)
        setenv("MSL_INIT_BOOTLOADER_BINARY_PATH", fakeInit.path, 1)
        defer { unsetenv("MSL_INIT_BOOTLOADER_BINARY_PATH") }

        let rootfs = ctx.root.appendingPathComponent("rootfs", isDirectory: true)
        try FileManager.default.createDirectory(at: rootfs, withIntermediateDirectories: true)

        let manager = ctx.makeManager()
        try manager.stageInitBinary(intoRootfs: rootfs)

        let bootloaderInUsrLocal = rootfs.appendingPathComponent("usr/local/bin/msl-init-bootloader", isDirectory: false)
        let bootloaderInSbin = rootfs.appendingPathComponent("sbin/msl-init-bootloader", isDirectory: false)
        let initInUsrLocal = rootfs.appendingPathComponent("usr/local/bin/msl-init", isDirectory: false)
        let waylandProfile = rootfs.appendingPathComponent("etc/profile.d/msl-wayland.sh", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bootloaderInUsrLocal.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bootloaderInSbin.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: initInUsrLocal.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: waylandProfile.path))
        XCTAssertTrue(try String(contentsOf: waylandProfile, encoding: .utf8).contains("WAYLAND_DISPLAY"))
    }

    func testStageInitBinaryInstallsWaylandProfileWithoutProxyBinary() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        let fakeInit = ctx.root.appendingPathComponent("msl-init-bootloader-fake", isDirectory: false)
        try Data(repeating: 0x41, count: 64).write(to: fakeInit)
        setenv("MSL_INIT_BOOTLOADER_BINARY_PATH", fakeInit.path, 1)
        defer { unsetenv("MSL_INIT_BOOTLOADER_BINARY_PATH") }

        let rootfs = ctx.root.appendingPathComponent("rootfs", isDirectory: true)
        try FileManager.default.createDirectory(at: rootfs, withIntermediateDirectories: true)

        try ctx.makeManager().stageInitBinary(intoRootfs: rootfs)

        let profile = rootfs.appendingPathComponent("etc/profile.d/msl-wayland.sh", isDirectory: false)
        let proxy = rootfs.appendingPathComponent("usr/local/bin/msl-wayland-proxy", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: proxy.path))
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

    func testParseContainerImageReferenceNormalizesDockerHubLibraryImage() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        let reference = try ctx.makeManager().parseContainerImageReference("debian:slim")
        XCTAssertEqual(reference.registry, "docker.io")
        XCTAssertEqual(reference.repository, "library/debian")
        XCTAssertEqual(reference.tag, "slim")
        XCTAssertEqual(reference.normalizedName, "docker.io/library/debian")
    }

    func testParseContainerImageReferenceKeepsExplicitRegistry() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        let reference = try ctx.makeManager().parseContainerImageReference("ghcr.io/example/app:latest")
        XCTAssertEqual(reference.registry, "ghcr.io")
        XCTAssertEqual(reference.repository, "example/app")
        XCTAssertEqual(reference.tag, "latest")
        XCTAssertEqual(reference.normalizedName, "ghcr.io/example/app")
    }

    func testInstallableNames() {
        let entries = [
            DistributionManifestEntry(
                id: "alpine-3.23-arm64",
                distro: "alpine",
                version: "3.23",
                arch: "arm64",
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
                id: "ubuntu-26.04-arm64",
                distro: "ubuntu",
                version: "26.04",
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
        let descriptors = [
            DistributionInstallDescriptor(canonicalName: "alpine-3.23", aliases: ["alpine"], manifestId: "alpine-3.23-arm64"),
            DistributionInstallDescriptor(canonicalName: "ubuntu-24.04", aliases: ["ubuntu"], manifestId: "ubuntu-24.04-arm64"),
            DistributionInstallDescriptor(canonicalName: "ubuntu-26.04", aliases: ["ubuntu-latest", "ubuntu-lts"], manifestId: "ubuntu-26.04-arm64"),
        ]
        let store = DistributionManifestStore(entries: entries, installDescriptors: descriptors)
        XCTAssertEqual(store.installableNames(), ["alpine-3.23", "ubuntu-24.04", "ubuntu-26.04"])
    }

    func testInstallableDescriptorsExposeUbuntuAlias() {
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
            aliases: ["ubuntu"],
            manifestId: entry.id
        )
        let store = DistributionManifestStore(entries: [entry], installDescriptors: [descriptor])
        XCTAssertEqual(store.resolve(alias: "ubuntu")?.id, entry.id)
        XCTAssertEqual(store.installableDescriptors(), [descriptor])
    }

    func testInstallCatalogContainsUbuntuLatestAndLtsAliases() {
        let descriptor = EmbeddedDistributionInstallCatalog.descriptors
            .first { $0.canonicalName == "ubuntu-26.04" }
        XCTAssertNotNil(descriptor)
        XCTAssertTrue(descriptor?.aliases.contains("ubuntu-latest") == true)
        XCTAssertTrue(descriptor?.aliases.contains("ubuntu-lts") == true)
    }

    func testInternalInstanceDefaultsToEphemeralTmpStorage() {
        let policy = DistributionInstanceMetadata.defaultTmpStoragePolicy(forNewInstanceNamed: "_imagewriter")
        XCTAssertEqual(policy.mode, "ephemeral")
        XCTAssertEqual(policy.sizeMiB, 1024)
        XCTAssertTrue(policy.resetOnStop)
    }

    func testRegularInstanceDefaultsToEphemeralTmpStorage() {
        let policy = DistributionInstanceMetadata.defaultTmpStoragePolicy(forNewInstanceNamed: "ubuntu")
        XCTAssertEqual(policy.mode, "ephemeral")
        XCTAssertEqual(policy.sizeMiB, 1024)
        XCTAssertTrue(policy.resetOnStop)
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

    func testReadOrRebuildInstanceMetadataDoesNotPersistForceEmbeddedOverride() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        let name = "ephemeral"
        let instanceDir = ctx.paths.distroDirectory(named: name)
        try FileManager.default.createDirectory(at: instanceDir, withIntermediateDirectories: true)
        let disk = ctx.paths.distroDiskFile(named: name)
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
            userConvergencePolicy: nil,
            tmpStorage: DistributionInstanceMetadata.TmpStoragePolicy(
                mode: "ephemeral",
                sizeMiB: 1024,
                resetOnStop: true
            )
        )
        let metadataURL = ctx.paths.distroMetadataFile(named: name)
        try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)

        setenv("MSL_TMP_STORAGE_FORCE_EMBEDDED", "1", 1)
        defer { unsetenv("MSL_TMP_STORAGE_FORCE_EMBEDDED") }

        let loaded = try ctx.makeManager().readOrRebuildInstanceMetadata(at: metadataURL)
        let persisted = try JSONDecoder().decode(
            DistributionInstanceMetadata.self,
            from: Data(contentsOf: metadataURL)
        )

        XCTAssertEqual(loaded.tmpStorage?.mode, "ephemeral")
        XCTAssertEqual(persisted.tmpStorage?.mode, "ephemeral")
        XCTAssertEqual(try loaded.resolveValidatedTmpStoragePolicy().mode, "embedded")
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

    func testInstalledInstancesExcludesReservedInternalInstanceByDefault() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        try ctx.makeInstance(name: "_imagewriter")
        try ctx.makeInstance(name: "_container")
        try ctx.makeInstance(name: "alpine")

        let names = ctx.makeManager()
            .installedInstances()
            .map(\.name)
        XCTAssertEqual(names, ["alpine"])
    }

    func testInstalledInstancesCanIncludeReservedInternalInstances() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        try ctx.makeInstance(name: "_imagewriter")
        try ctx.makeInstance(name: "_container")
        try ctx.makeInstance(name: "alpine")

        let names = ctx.makeManager()
            .installedInstances(includeReserved: true)
            .map(\.name)
        XCTAssertEqual(names, ["_container", "_imagewriter", "alpine"])
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

        let localTarball = try ctx.makeRootfsArchive(named: "rootfs.tar.gz")

        let fakeInit = ctx.root.appendingPathComponent("msl-init-bootloader-fake", isDirectory: false)
        try Data(repeating: 0x42, count: 64).write(to: fakeInit)
        setenv("MSL_INIT_BOOTLOADER_BINARY_PATH", fakeInit.path, 1)
        defer { unsetenv("MSL_INIT_BOOTLOADER_BINARY_PATH") }

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

    func testCreateImageWithImagewriterReportsGuestSubstageAndLogPath() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        let localTarball = try ctx.makeRootfsArchive(named: "rootfs.tar.gz")

        let fakeInit = ctx.root.appendingPathComponent("msl-init-bootloader-fake-substage", isDirectory: false)
        try Data(repeating: 0x42, count: 64).write(to: fakeInit)
        setenv("MSL_INIT_BOOTLOADER_BINARY_PATH", fakeInit.path, 1)
        defer { unsetenv("MSL_INIT_BOOTLOADER_BINARY_PATH") }

        let fakeImagewriter = ctx.root.appendingPathComponent("imagewriter-fail-substage.sh", isDirectory: false)
        try ctx.makeShellScript(
            at: fakeImagewriter,
            contents: """
            #!/bin/sh
            echo "imagewriter_guest_failure_detected mode=stage2 stage=rootfs_copy stdout_log=/tmp/imagewriter-stage2.stdout.log stderr_log=/tmp/imagewriter-stage2.stderr.log" >&2
            exit 1
            """
        )
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
            XCTAssertTrue(runtime.message.contains("stage=rootfs_copy"))
            XCTAssertTrue(runtime.message.contains("see guest log: /tmp/imagewriter-stage2.stderr.log"))
        }
    }

    func testCreateImageWithImagewriterReportsWorkerStartupSerialLogHint() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        let localTarball = try ctx.makeRootfsArchive(named: "rootfs.tar.gz")

        let fakeInit = ctx.root.appendingPathComponent("msl-init-bootloader-fake-worker-startup", isDirectory: false)
        try Data(repeating: 0x42, count: 64).write(to: fakeInit)
        setenv("MSL_INIT_BOOTLOADER_BINARY_PATH", fakeInit.path, 1)
        defer { unsetenv("MSL_INIT_BOOTLOADER_BINARY_PATH") }

        let fakeImagewriter = ctx.root.appendingPathComponent("imagewriter-fail-worker-startup.sh", isDirectory: false)
        try ctx.makeShellScript(
            at: fakeImagewriter,
            contents: """
            #!/bin/sh
            echo "error: worker did not register in time for instance '_imagewriter'" >&2
            exit 1
            """
        )
        setenv("MSL_IMAGEWRITER_BUILD_SCRIPT", fakeImagewriter.path, 1)
        defer { unsetenv("MSL_IMAGEWRITER_BUILD_SCRIPT") }

        let workerSerialLog = ctx.paths
            .workerRuntimeDirectory(named: "_imagewriter")
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("serial-console.log", isDirectory: false)
        try FileManager.default.createDirectory(at: workerSerialLog.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "panic".write(to: workerSerialLog, atomically: true, encoding: .utf8)

        let manager = ctx.makeManager()
        XCTAssertThrowsError(try manager.createImageWithImagewriter(
            name: "python",
            targetAlias: nil,
            localFilePath: localTarball.path,
            rebuild: false,
            diskSizeGB: nil,
            mslExecutablePath: "/usr/bin/true"
        )) { error in
            guard let runtime = error as? MSLRuntimeError else {
                return XCTFail("unexpected error type: \(error)")
            }
            XCTAssertTrue(runtime.message.contains("stage=worker_startup"))
            XCTAssertTrue(runtime.message.contains("see guest serial log: \(workerSerialLog.path)"))
        }
    }

    func testCreateImageWithImagewriterUses16GiBDefaultWhenDiskSizeIsNil() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        let localTarball = try ctx.makeRootfsArchive(named: "rootfs.tar.gz")

        let fakeInit = ctx.root.appendingPathComponent("msl-init-bootloader-fake-default-size", isDirectory: false)
        try Data(repeating: 0x42, count: 64).write(to: fakeInit)
        setenv("MSL_INIT_BOOTLOADER_BINARY_PATH", fakeInit.path, 1)
        defer { unsetenv("MSL_INIT_BOOTLOADER_BINARY_PATH") }

        let recordedSize = ctx.root.appendingPathComponent("imagewriter-size.txt", isDirectory: false)
        let fakeImagewriter = ctx.root.appendingPathComponent("imagewriter-success.sh", isDirectory: false)
        try ctx.makeShellScript(
            at: fakeImagewriter,
            contents: """
            #!/bin/sh
            printf '%s' "$IMAGE_SIZE_MB" > "\(recordedSize.path)"
            : > "$OUTPUT_RAW"
            exit 0
            """
        )
        setenv("MSL_IMAGEWRITER_BUILD_SCRIPT", fakeImagewriter.path, 1)
        defer { unsetenv("MSL_IMAGEWRITER_BUILD_SCRIPT") }

        let manager = ctx.makeManager()
        _ = try manager.createImageWithImagewriter(
            name: "dev",
            targetAlias: nil,
            localFilePath: localTarball.path,
            rebuild: false,
            diskSizeGB: nil,
            mslExecutablePath: "/usr/bin/true"
        )

        let size = try String(contentsOf: recordedSize, encoding: .utf8)
        XCTAssertEqual(size, "16384")
    }

    func testCreateImageWithImagewriterRequiresExistingErofsImagewriter() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        let localTarball = try ctx.makeRootfsArchive(named: "rootfs.tar.gz")

        let fakeInit = ctx.root.appendingPathComponent("msl-init-bootloader-fake-require-erofs", isDirectory: false)
        try Data(repeating: 0x42, count: 64).write(to: fakeInit)
        setenv("MSL_INIT_BOOTLOADER_BINARY_PATH", fakeInit.path, 1)
        defer { unsetenv("MSL_INIT_BOOTLOADER_BINARY_PATH") }

        let recordedEnv = ctx.root.appendingPathComponent("imagewriter-env.txt", isDirectory: false)
        let fakeImagewriter = ctx.root.appendingPathComponent("imagewriter-success-record-env.sh", isDirectory: false)
        try ctx.makeShellScript(
            at: fakeImagewriter,
            contents: """
            #!/bin/sh
            {
              printf 'allow=%s\n' "$IMAGEWRITER_ALLOW_SETUP_WHEN_MISSING"
              printf 'required_fs=%s\n' "$IMAGEWRITER_REQUIRED_FS"
              printf 'force_setup=%s\n' "$IMAGEWRITER_FORCE_SETUP"
              printf 'rootfs_tarball=%s\n' "$ROOTFS_TARBALL"
              printf 'rootfs_dir=%s\n' "$ROOTFS_DIR"
            } > "\(recordedEnv.path)"
            : > "$OUTPUT_RAW"
            exit 0
            """
        )
        setenv("MSL_IMAGEWRITER_BUILD_SCRIPT", fakeImagewriter.path, 1)
        defer { unsetenv("MSL_IMAGEWRITER_BUILD_SCRIPT") }

        let manager = ctx.makeManager()
        _ = try manager.createImageWithImagewriter(
            name: "dev",
            targetAlias: nil,
            localFilePath: localTarball.path,
            rebuild: false,
            diskSizeGB: nil,
            mslExecutablePath: "/usr/bin/true"
        )

        let recorded = try String(contentsOf: recordedEnv, encoding: .utf8)
        XCTAssertTrue(recorded.contains("allow=0"))
        XCTAssertTrue(recorded.contains("required_fs=erofs"))
        XCTAssertTrue(recorded.contains("force_setup=0"))
        XCTAssertTrue(recorded.contains("rootfs_tarball=/"))
        XCTAssertTrue(recorded.contains("rootfs_dir="))
        XCTAssertFalse(recorded.contains("rootfs_dir=/"))
    }

    func testCreateImageWithImagewriterAcceptsAbsoluteShellSymlink() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        let localTarball = try ctx.makeRootfsArchiveWithAbsoluteShellSymlink(named: "alpine-rootfs.tar.gz")

        let fakeInit = ctx.root.appendingPathComponent("msl-init-bootloader-fake-symlink-shell", isDirectory: false)
        try Data(repeating: 0x42, count: 64).write(to: fakeInit)
        setenv("MSL_INIT_BOOTLOADER_BINARY_PATH", fakeInit.path, 1)
        defer { unsetenv("MSL_INIT_BOOTLOADER_BINARY_PATH") }

        let recordedEnv = ctx.root.appendingPathComponent("imagewriter-symlink-env.txt", isDirectory: false)
        let fakeImagewriter = ctx.root.appendingPathComponent("imagewriter-success-symlink.sh", isDirectory: false)
        try ctx.makeShellScript(
            at: fakeImagewriter,
            contents: """
            #!/bin/sh
            {
              printf 'rootfs_tarball=%s\n' "$ROOTFS_TARBALL"
              printf 'rootfs_dir=%s\n' "$ROOTFS_DIR"
            } > "\(recordedEnv.path)"
            : > "$OUTPUT_RAW"
            exit 0
            """
        )
        setenv("MSL_IMAGEWRITER_BUILD_SCRIPT", fakeImagewriter.path, 1)
        defer { unsetenv("MSL_IMAGEWRITER_BUILD_SCRIPT") }

        let manager = ctx.makeManager()
        _ = try manager.createImageWithImagewriter(
            name: "alpine",
            targetAlias: nil,
            localFilePath: localTarball.path,
            rebuild: false,
            diskSizeGB: nil,
            mslExecutablePath: "/usr/bin/true"
        )

        let recorded = try String(contentsOf: recordedEnv, encoding: .utf8)
        XCTAssertTrue(recorded.contains("rootfs_tarball=/"))
        XCTAssertTrue(recorded.contains("rootfs_dir="))
        XCTAssertFalse(recorded.contains("rootfs_dir=/"))
    }

    func testAlpineManifestInstallPassesSudoRootFSPackageToImagewriter() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        let localTarball = try ctx.makeRootfsArchiveWithAbsoluteShellSymlink(named: "alpine-rootfs.tar.gz")
        let sha = try ctx.sha256(of: localTarball)
        let entry = DistributionManifestEntry(
            id: "alpine-3.23-arm64",
            distro: "alpine",
            version: "3.23",
            arch: "arm64",
            tarballURL: "https://example.com/rootfs.tar.gz",
            sha256: sha,
            signatureURL: "https://example.com/rootfs.tar.gz.asc",
            checksumURL: "https://example.com/rootfs.tar.gz.sha256",
            signatureTarget: "artifact",
            keyFingerprint: "F1",
            supportState: .supported
        )
        let descriptor = DistributionInstallDescriptor(
            canonicalName: "alpine-3.23",
            aliases: ["alpine-3.23"],
            manifestId: entry.id
        )
        try ctx.seedManifestCache(entry: entry, tarball: localTarball, sha256: sha)

        let fakeInit = ctx.root.appendingPathComponent("msl-init-bootloader-fake-alpine-packages", isDirectory: false)
        try Data(repeating: 0x45, count: 64).write(to: fakeInit)
        setenv("MSL_INIT_BOOTLOADER_BINARY_PATH", fakeInit.path, 1)
        defer { unsetenv("MSL_INIT_BOOTLOADER_BINARY_PATH") }

        let recordedEnv = ctx.root.appendingPathComponent("imagewriter-alpine-packages-env.txt", isDirectory: false)
        let fakeImagewriter = ctx.root.appendingPathComponent("imagewriter-success-alpine-packages.sh", isDirectory: false)
        try ctx.makeShellScript(
            at: fakeImagewriter,
            contents: """
            #!/bin/sh
            {
              printf 'rootfs_packages=%s\n' "$IMAGEWRITER_ROOTFS_PACKAGES"
              printf 'imagewriter_packages=%s\n' "$IMAGEWRITER_PACKAGES"
              printf 'rootfs_tarball=%s\n' "$ROOTFS_TARBALL"
              printf 'rootfs_dir=%s\n' "$ROOTFS_DIR"
            } > "\(recordedEnv.path)"
            : > "$OUTPUT_RAW"
            exit 0
            """
        )
        setenv("MSL_IMAGEWRITER_BUILD_SCRIPT", fakeImagewriter.path, 1)
        defer { unsetenv("MSL_IMAGEWRITER_BUILD_SCRIPT") }

        let store = DistributionManifestStore(entries: [entry], installDescriptors: [descriptor])
        let manager = DistributionManager(
            paths: ctx.paths,
            logger: MSLLogger(logFile: ctx.paths.logs.appendingPathComponent("test.log", isDirectory: false)),
            manifestStore: store
        )
        _ = try manager.createImageWithImagewriter(
            name: "alpine",
            targetAlias: "alpine-3.23",
            localFilePath: nil,
            rebuild: false,
            diskSizeGB: nil,
            mslExecutablePath: "/usr/bin/true"
        )

        let recorded = try String(contentsOf: recordedEnv, encoding: .utf8)
        XCTAssertTrue(recorded.contains("rootfs_packages=sudo"))
        XCTAssertTrue(recorded.contains("imagewriter_packages=btrfs-progs"))
        XCTAssertTrue(recorded.contains("rootfs_tarball=/"))
        XCTAssertTrue(recorded.contains("rootfs_dir="))
        XCTAssertFalse(recorded.contains("rootfs_dir=/"))
    }

    func testNonAlpineManifestInstallDoesNotInjectRootFSPackages() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        let localTarball = try ctx.makeRootfsArchive(named: "debian-rootfs.tar.gz")
        let sha = try ctx.sha256(of: localTarball)
        let entry = DistributionManifestEntry(
            id: "debian-trixie-arm64",
            distro: "debian",
            version: "trixie",
            arch: "arm64",
            tarballURL: "https://example.com/rootfs.tar.gz",
            sha256: sha,
            signatureURL: "https://example.com/rootfs.tar.gz.asc",
            checksumURL: "https://example.com/rootfs.tar.gz.sha256",
            signatureTarget: "artifact",
            keyFingerprint: "F1",
            supportState: .supported
        )
        let descriptor = DistributionInstallDescriptor(
            canonicalName: "debian-trixie",
            aliases: ["debian-trixie"],
            manifestId: entry.id
        )
        try ctx.seedManifestCache(entry: entry, tarball: localTarball, sha256: sha)

        let fakeInit = ctx.root.appendingPathComponent("msl-init-bootloader-fake-debian-packages", isDirectory: false)
        try Data(repeating: 0x46, count: 64).write(to: fakeInit)
        setenv("MSL_INIT_BOOTLOADER_BINARY_PATH", fakeInit.path, 1)
        defer { unsetenv("MSL_INIT_BOOTLOADER_BINARY_PATH") }

        let recordedEnv = ctx.root.appendingPathComponent("imagewriter-debian-packages-env.txt", isDirectory: false)
        let fakeImagewriter = ctx.root.appendingPathComponent("imagewriter-success-debian-packages.sh", isDirectory: false)
        try ctx.makeShellScript(
            at: fakeImagewriter,
            contents: """
            #!/bin/sh
            printf 'rootfs_packages=%s\n' "$IMAGEWRITER_ROOTFS_PACKAGES" > "\(recordedEnv.path)"
            : > "$OUTPUT_RAW"
            exit 0
            """
        )
        setenv("MSL_IMAGEWRITER_BUILD_SCRIPT", fakeImagewriter.path, 1)
        defer { unsetenv("MSL_IMAGEWRITER_BUILD_SCRIPT") }

        let store = DistributionManifestStore(entries: [entry], installDescriptors: [descriptor])
        let manager = DistributionManager(
            paths: ctx.paths,
            logger: MSLLogger(logFile: ctx.paths.logs.appendingPathComponent("test.log", isDirectory: false)),
            manifestStore: store
        )
        _ = try manager.createImageWithImagewriter(
            name: "debian",
            targetAlias: "debian-trixie",
            localFilePath: nil,
            rebuild: false,
            diskSizeGB: nil,
            mslExecutablePath: "/usr/bin/true"
        )

        let recorded = try String(contentsOf: recordedEnv, encoding: .utf8)
        XCTAssertEqual(recorded, "rootfs_packages=\n")
    }

    func testHTTPStatusValidationRejects404() {
        XCTAssertTrue(DistributionManager.isSuccessfulHTTPStatus(200))
        XCTAssertTrue(DistributionManager.isSuccessfulHTTPStatus(204))
        XCTAssertFalse(DistributionManager.isSuccessfulHTTPStatus(301))
        XCTAssertFalse(DistributionManager.isSuccessfulHTTPStatus(404))
        XCTAssertFalse(DistributionManager.isSuccessfulHTTPStatus(500))
    }

    func testManifestCacheRejectsVerifiedRecordWhenTarballChecksumDiffers() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        let tarball = ctx.root.appendingPathComponent("rootfs.tar.gz", isDirectory: false)
        try Data("not the expected archive".utf8).write(to: tarball, options: .atomic)
        let expectedSHA = SHA256.hash(data: Data("expected".utf8)).map { String(format: "%02x", $0) }.joined()
        let actualSHA = try ctx.sha256(of: tarball)
        let verifiedPath = ctx.root.appendingPathComponent("verified.json", isDirectory: false)
        let entry = DistributionManifestEntry(
            id: "debian-trixie-arm64",
            distro: "debian",
            version: "trixie",
            arch: "arm64",
            tarballURL: "https://example.com/rootfs.tar.gz",
            sha256: expectedSHA,
            signatureURL: "https://example.com/rootfs.tar.gz.asc",
            checksumURL: "https://example.com/rootfs.tar.gz.sha256",
            signatureTarget: "artifact",
            keyFingerprint: "F1",
            supportState: .supported
        )
        let verified = DistributionVerifiedRecord(
            tarballPath: tarball.path,
            sha256: expectedSHA,
            signatureFingerprint: "F1",
            verifiedAtEpochMs: nowEpochMs(),
            manifestId: entry.id
        )
        try JSONEncoder().encode(verified).write(to: verifiedPath, options: .atomic)

        let status = try ctx.makeManager().manifestCacheRecordIfUsable(
            entry: entry,
            tarballPath: tarball,
            verifiedPath: verifiedPath
        )

        switch status {
        case .invalidChecksum(let expected, let actual):
            XCTAssertEqual(expected, expectedSHA)
            XCTAssertEqual(actual, actualSHA)
        default:
            XCTFail("expected invalid checksum, got \(status)")
        }
    }

    func testCreateImageUses1GiBDefaultForInternalImagewriterWhenDiskSizeIsNil() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        let localTarball = ctx.root.appendingPathComponent("rootfs-imagewriter.tar.gz", isDirectory: false)
        let rootfsDir = ctx.root.appendingPathComponent("rootfs-imagewriter-src", isDirectory: true)
        try FileManager.default.createDirectory(at: rootfsDir, withIntermediateDirectories: true)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", localTarball.path, "-C", rootfsDir.path, "."]
        try tar.run()
        tar.waitUntilExit()
        XCTAssertEqual(tar.terminationStatus, 0)

        let recordedSize = ctx.root.appendingPathComponent("bootstrap-size.txt", isDirectory: false)
        let fakeMkfs = ctx.root.appendingPathComponent("fake-mkfs.sh", isDirectory: false)
        try ctx.makeShellScript(
            at: fakeMkfs,
            contents: """
            #!/bin/sh
            while [ "$#" -gt 0 ]; do
              case "$1" in
                --size-gb)
                  shift
                  printf '%s' "$1" > "\(recordedSize.path)"
                  ;;
              esac
              shift
            done
            exit 0
            """
        )
        setenv("MSL_EXT4_MKFS_HELPER_PATH", fakeMkfs.path, 1)
        defer { unsetenv("MSL_EXT4_MKFS_HELPER_PATH") }

        let fakePopulate = ctx.root.appendingPathComponent("fake-populate.sh", isDirectory: false)
        try ctx.makeShellScript(
            at: fakePopulate,
            contents: """
            #!/bin/sh
            while [ "$#" -gt 0 ]; do
              case "$1" in
                --output)
                  shift
                  : > "$1"
                  ;;
              esac
              shift
            done
            exit 0
            """
        )
        setenv("MSL_EXT4_HELPER_PATH", fakePopulate.path, 1)
        defer { unsetenv("MSL_EXT4_HELPER_PATH") }

        let fakeInit = ctx.root.appendingPathComponent("msl-init-bootloader-fake-bootstrap-size", isDirectory: false)
        try Data(repeating: 0x44, count: 64).write(to: fakeInit)
        setenv("MSL_INIT_BOOTLOADER_BINARY_PATH", fakeInit.path, 1)
        defer { unsetenv("MSL_INIT_BOOTLOADER_BINARY_PATH") }

        let manager = ctx.makeManager()
        _ = try manager.createImage(
            name: "_imagewriter",
            targetAlias: nil,
            localFilePath: localTarball.path,
            rebuild: false,
            diskSizeGB: nil
        )

        let size = try String(contentsOf: recordedSize, encoding: .utf8)
        XCTAssertEqual(size, "1")
    }

    func testCreateImageWithImagewriterHonorsExplicitDiskSizeGB() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        let localTarball = try ctx.makeRootfsArchive(named: "rootfs.tar.gz")

        let fakeInit = ctx.root.appendingPathComponent("msl-init-bootloader-fake-explicit-size", isDirectory: false)
        try Data(repeating: 0x43, count: 64).write(to: fakeInit)
        setenv("MSL_INIT_BOOTLOADER_BINARY_PATH", fakeInit.path, 1)
        defer { unsetenv("MSL_INIT_BOOTLOADER_BINARY_PATH") }

        let recordedSize = ctx.root.appendingPathComponent("imagewriter-size-explicit.txt", isDirectory: false)
        let fakeImagewriter = ctx.root.appendingPathComponent("imagewriter-success-explicit.sh", isDirectory: false)
        try ctx.makeShellScript(
            at: fakeImagewriter,
            contents: """
            #!/bin/sh
            printf '%s' "$IMAGE_SIZE_MB" > "\(recordedSize.path)"
            : > "$OUTPUT_RAW"
            exit 0
            """
        )
        setenv("MSL_IMAGEWRITER_BUILD_SCRIPT", fakeImagewriter.path, 1)
        defer { unsetenv("MSL_IMAGEWRITER_BUILD_SCRIPT") }

        let manager = ctx.makeManager()
        _ = try manager.createImageWithImagewriter(
            name: "dev",
            targetAlias: nil,
            localFilePath: localTarball.path,
            rebuild: false,
            diskSizeGB: 16,
            mslExecutablePath: "/usr/bin/true"
        )

        let size = try String(contentsOf: recordedSize, encoding: .utf8)
        XCTAssertEqual(size, "16384")
    }

    func testCreateImageWithImagewriterReportsImagewriterVerifyStageHint() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        let localTarball = try ctx.makeRootfsArchive(named: "rootfs.tar.gz")

        let fakeInit = ctx.root.appendingPathComponent("msl-init-bootloader-fake-verify-stage", isDirectory: false)
        try Data(repeating: 0x43, count: 64).write(to: fakeInit)
        setenv("MSL_INIT_BOOTLOADER_BINARY_PATH", fakeInit.path, 1)
        defer { unsetenv("MSL_INIT_BOOTLOADER_BINARY_PATH") }

        let fakeImagewriter = ctx.root.appendingPathComponent("imagewriter-verify-stage.sh", isDirectory: false)
        try Data("#!/bin/sh\nexit 24\n".utf8).write(to: fakeImagewriter)
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
            XCTAssertTrue(runtime.message.contains("stage=imagewriter_verify"))
        }
    }

    func testCreateImageWithImagewriterReportsImagewriterMissingStageHint() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        let localTarball = try ctx.makeRootfsArchive(named: "rootfs.tar.gz")

        let fakeInit = ctx.root.appendingPathComponent("msl-init-bootloader-fake-missing-stage", isDirectory: false)
        try Data(repeating: 0x44, count: 64).write(to: fakeInit)
        setenv("MSL_INIT_BOOTLOADER_BINARY_PATH", fakeInit.path, 1)
        defer { unsetenv("MSL_INIT_BOOTLOADER_BINARY_PATH") }

        let fakeImagewriter = ctx.root.appendingPathComponent("imagewriter-missing-stage.sh", isDirectory: false)
        try Data("#!/bin/sh\nexit 25\n".utf8).write(to: fakeImagewriter)
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
            XCTAssertTrue(runtime.message.contains("stage=imagewriter_missing"))
        }
    }

    func testImagewriterStopArgumentsUseStopSubcommand() {
        XCTAssertEqual(
            DistributionManager.imagewriterStopArguments(instanceName: "_imagewriter"),
            ["--instance", "_imagewriter", "stop"]
        )
    }

    func testCreateImageWithImagewriterFailureStillRunsStopSubcommandCleanup() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        let localTarball = try ctx.makeRootfsArchive(named: "rootfs.tar.gz")

        let fakeInit = ctx.root.appendingPathComponent("msl-init-bootloader-fake", isDirectory: false)
        try Data(repeating: 0x24, count: 64).write(to: fakeInit)
        setenv("MSL_INIT_BOOTLOADER_BINARY_PATH", fakeInit.path, 1)
        defer { unsetenv("MSL_INIT_BOOTLOADER_BINARY_PATH") }

        let fakeImagewriter = ctx.root.appendingPathComponent("imagewriter-fail.sh", isDirectory: false)
        try Data("#!/bin/sh\nexit 22\n".utf8).write(to: fakeImagewriter)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeImagewriter.path)
        setenv("MSL_IMAGEWRITER_BUILD_SCRIPT", fakeImagewriter.path, 1)
        defer { unsetenv("MSL_IMAGEWRITER_BUILD_SCRIPT") }

        let recordedArgs = ctx.root.appendingPathComponent("imagewriter-stop-args.txt", isDirectory: false)
        let fakeMSL = ctx.root.appendingPathComponent("fake-msl.sh", isDirectory: false)
        let fakeMSLScript = """
        #!/bin/sh
        printf '%s\n' "$@" > "\(recordedArgs.path)"
        exit 0
        """
        try Data(fakeMSLScript.utf8).write(to: fakeMSL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeMSL.path)

        let manager = ctx.makeManager()
        XCTAssertThrowsError(try manager.createImageWithImagewriter(
            name: "dev",
            targetAlias: nil,
            localFilePath: localTarball.path,
            rebuild: false,
            diskSizeGB: nil,
            mslExecutablePath: fakeMSL.path
        )) { error in
            guard let runtime = error as? MSLRuntimeError else {
                return XCTFail("unexpected error type: \(error)")
            }
            XCTAssertTrue(runtime.message.contains("stage=btrfs_build"))
        }

        let args = try String(contentsOf: recordedArgs, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(args, ["--instance", "_imagewriter", "stop"])
    }

    func testCreateImageFromRawCopiesDiskAndWritesMetadata() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        let raw = ctx.root.appendingPathComponent("custom.raw", isDirectory: false)
        try Data([0xde, 0xad, 0xbe, 0xef]).write(to: raw)

        let dir = try ctx.makeManager().createImageFromRaw(
            name: "custom",
            rawDiskPath: raw.path,
            rebuild: false
        )
        XCTAssertEqual(dir.path, ctx.paths.distroDirectory(named: "custom").path)

        let disk = ctx.paths.distroDiskFile(named: "custom")
        let copied = try Data(contentsOf: disk)
        XCTAssertEqual(copied, Data([0xde, 0xad, 0xbe, 0xef]))

        let metadataURL = ctx.paths.distroMetadataFile(named: "custom")
        let metadata = try JSONDecoder().decode(DistributionInstanceMetadata.self, from: Data(contentsOf: metadataURL))
        XCTAssertEqual(metadata.source.sourceType, "local-raw")
        XCTAssertEqual(metadata.source.localPath, raw.path)
        XCTAssertEqual(metadata.source.tarballFileName, "custom.raw")
        XCTAssertEqual(metadata.diskPath, disk.path)
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

    func testResetWritableStateCopiesTemplateToStateDisk() throws {
        let ctx = try DistributionContext.make()
        defer { ctx.cleanup() }

        let instanceDir = ctx.paths.distroDirectory(named: "python")
        try FileManager.default.createDirectory(at: instanceDir, withIntermediateDirectories: true)
        let base = ctx.paths.distroBaseDiskFile(named: "python")
        let state = ctx.paths.distroStateDiskFile(named: "python")
        let template = ctx.paths.distroStateTemplateDiskFile(named: "python")
        try Data([0xe0]).write(to: base)
        try Data([0x01, 0x02, 0x03]).write(to: template)
        try Data([0xff]).write(to: state)

        let metadata = DistributionInstanceMetadata(
            name: "python",
            createdAtEpochMs: nowEpochMs(),
            source: DistributionSourceRecord(
                sourceType: "container-remote",
                tarballFileName: "rootfs.oci",
                sha256: "abc",
                verifiedAtEpochMs: nowEpochMs()
            ),
            diskPath: ctx.paths.distroDiskFile(named: "python").path,
            baseDiskPath: base.path,
            stateDiskPath: state.path,
            rootMode: .readonlyBaseCowState,
            kernelProfileRef: nil,
            userConvergencePolicy: nil
        )
        try JSONEncoder().encode(metadata).write(to: ctx.paths.distroMetadataFile(named: "python"), options: .atomic)

        let resetURL = try ctx.makeManager().resetWritableState(name: "python")
        XCTAssertEqual(resetURL.path, state.path)
        XCTAssertEqual(try Data(contentsOf: state), Data([0x01, 0x02, 0x03]))
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

    func makeShellScript(at path: URL, contents: String) throws {
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }

    func writeBundledToolManifest(at path: URL, bundleVersion: String, toolURLs: [String: URL]) throws {
        var tools: [BundledToolRecord] = []
        for name in toolURLs.keys.sorted() {
            guard let url = toolURLs[name] else { continue }
            let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            tools.append(
                BundledToolRecord(
                    name: name,
                    platform: "darwin-arm64",
                    version: "test-version",
                    checksum: digest,
                    relativePath: url.lastPathComponent
                )
            )
        }
        let manifest = BundledToolManifest(
            bundleVersion: bundleVersion,
            generatedAtEpochMs: nowEpochMs(),
            tools: tools
        )
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: path, options: .atomic)
    }

    func sha256(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    func seedManifestCache(
        entry: DistributionManifestEntry,
        tarball: URL,
        sha256: String
    ) throws {
        let tarballFileName = URL(string: entry.tarballURL)?.lastPathComponent ?? "\(entry.id).tar"
        let cacheDir = paths.cacheDownloadsDir
            .appendingPathComponent(entry.distro, isDirectory: true)
            .appendingPathComponent(entry.version, isDirectory: true)
            .appendingPathComponent(entry.arch, isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let cachedTarball = cacheDir.appendingPathComponent(tarballFileName, isDirectory: false)
        try FileManager.default.copyItem(at: tarball, to: cachedTarball)
        let verified = DistributionVerifiedRecord(
            tarballPath: cachedTarball.path,
            sha256: sha256,
            signatureFingerprint: entry.keyFingerprint,
            verifiedAtEpochMs: nowEpochMs(),
            manifestId: entry.id
        )
        try JSONEncoder().encode(verified).write(
            to: cacheDir.appendingPathComponent("verified.json", isDirectory: false),
            options: .atomic
        )
    }

    func fileMode(at url: URL) throws -> UInt16 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let mode = attributes[.posixPermissions] as? NSNumber else {
            XCTFail("missing posixPermissions for \(url.path)")
            return 0
        }
        return mode.uint16Value
    }

    func makeRootfsArchive(named name: String) throws -> URL {
        let sourceDir = root.appendingPathComponent("\(name)-src", isDirectory: true)
        let binDir = sourceDir.appendingPathComponent("bin", isDirectory: true)
        let etcDir = sourceDir.appendingPathComponent("etc", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: etcDir, withIntermediateDirectories: true)
        let shellPath = binDir.appendingPathComponent("sh", isDirectory: false)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: shellPath, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shellPath.path)
        try Data("# placeholder\n".utf8).write(to: etcDir.appendingPathComponent("fstab"), options: .atomic)

        let archive = root.appendingPathComponent(name, isDirectory: false)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-czf", archive.path, "-C", sourceDir.path, "."]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return archive
    }

    func makeRootfsArchiveWithAbsoluteShellSymlink(named name: String) throws -> URL {
        let sourceDir = root.appendingPathComponent("\(name)-src", isDirectory: true)
        let binDir = sourceDir.appendingPathComponent("bin", isDirectory: true)
        let etcDir = sourceDir.appendingPathComponent("etc", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: etcDir, withIntermediateDirectories: true)

        let busyboxPath = binDir.appendingPathComponent("busybox", isDirectory: false)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: busyboxPath, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: busyboxPath.path)
        try FileManager.default.createSymbolicLink(
            atPath: binDir.appendingPathComponent("sh", isDirectory: false).path,
            withDestinationPath: "/bin/busybox"
        )
        try Data("# placeholder\n".utf8).write(to: etcDir.appendingPathComponent("fstab"), options: .atomic)

        let archive = root.appendingPathComponent(name, isDirectory: false)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-czf", archive.path, "-C", sourceDir.path, "."]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return archive
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
