import Foundation
import CryptoKit
import Darwin

struct ProcessResult {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

struct ProcessExecutor {
    func run(
        _ executable: String,
        _ arguments: [String],
        captureOutput: Bool = false,
        environment: [String: String] = [:]
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var outPipe: Pipe?
        var errPipe: Pipe?
        if captureOutput {
            let op = Pipe()
            let ep = Pipe()
            process.standardOutput = op
            process.standardError = ep
            outPipe = op
            errPipe = ep
        } else {
            process.standardInput = nil
            process.standardOutput = nil
            process.standardError = nil
        }

        if !environment.isEmpty {
            var merged = ProcessInfo.processInfo.environment
            for (k, v) in environment {
                merged[k] = v
            }
            process.environment = merged
        }

        var outData = Data()
        var errData = Data()
        let readGroup = DispatchGroup()
        if captureOutput, let outPipe, let errPipe {
            readGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                readGroup.leave()
            }
            readGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                readGroup.leave()
            }
        }

        do {
            try process.run()
        } catch {
            if captureOutput {
                outPipe?.fileHandleForWriting.closeFile()
                errPipe?.fileHandleForWriting.closeFile()
                readGroup.wait()
            }
            throw MSLRuntimeError("failed to execute \(executable): \(error)")
        }

        if captureOutput {
            outPipe?.fileHandleForWriting.closeFile()
            errPipe?.fileHandleForWriting.closeFile()
        }

        process.waitUntilExit()
        if captureOutput {
            readGroup.wait()
        }

        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""

        return ProcessResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    func findExecutable(_ names: [String]) -> String? {
        for name in names {
            if name.contains("/") {
                if FileManager.default.isExecutableFile(atPath: name) {
                    return name
                }
                continue
            }
            let result = try? run("/usr/bin/env", ["which", name], captureOutput: true)
            if let result, result.exitCode == 0 {
                let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty {
                    return path
                }
            }
        }
        return nil
    }
}

private struct RootFSMaterializationResult {
    var source: DistributionSourceSelection
    var sourceRecord: DistributionSourceRecord
    var rootfsDir: URL?
    var ociLayoutDir: URL?
    var defaultExec: DistributionInstanceMetadata.DefaultExec?
    var shellAvailable: Bool?
    var imagewriterPackages: String?
    var imagewriterRootFSPackages: String?
    var sourceArchivePath: String?
    var cleanupRoot: URL
}

private struct ContainerRuntimeValidationSummary {
    var shellAvailable: Bool
    var resolvedDefaultExec: DistributionInstanceMetadata.DefaultExec?
}

final class DistributionManager {
    static let reservedInternalInstanceNames: Set<String> = ["_imagewriter", "_container"]
    static let defaultBootstrapDiskSizeGB = 8
    static let defaultInternalImagewriterBootstrapDiskSizeGB = 1
    static let defaultImagewriterDiskSizeGB = 16
    private static let containerRuntimeAlias = "container-runtime"
    private static let containerRuntimeInstanceName = "_container"
    private static let defaultImagewriterPackages = "btrfs-progs e2fsprogs erofs-utils util-linux tar zstd xz coreutils"
    private static let alpineDistributionRootFSPackages = "sudo"
    private static let containerRuntimeImagewriterPackages = [
        "btrfs-progs", "e2fsprogs", "erofs-utils", "util-linux", "tar", "zstd", "xz", "coreutils",
        "openrc", "bash", "ca-certificates", "iproute2", "iptables", "nftables",
        "containerd", "buildkit", "nerdctl", "runc", "cni-plugins", "duperemove"
    ].joined(separator: " ")

    private let paths: MSLPaths
    private let logger: MSLLogger
    private let fileManager: FileManager
    private let manifestStore: DistributionManifestStore
    private let process: ProcessExecutor
    private let environment: [String: String]

    init(
        paths: MSLPaths,
        logger: MSLLogger,
        fileManager: FileManager = .default,
        manifestStore: DistributionManifestStore = DistributionManifestStore(),
        process: ProcessExecutor = ProcessExecutor(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.paths = paths
        self.logger = logger
        self.fileManager = fileManager
        self.manifestStore = manifestStore
        self.process = process
        self.environment = environment
    }

    func installableDistributionNames() -> [String] {
        installableDistributions().map(\.canonicalName)
    }

    func installableDistributions() -> [DistributionInstallDescriptor] {
        manifestStore.installableDescriptors()
            .sorted { $0.canonicalName.localizedCaseInsensitiveCompare($1.canonicalName) == .orderedAscending }
    }

    func installedInstances(includeReserved: Bool = false) -> [InstalledInstanceDescriptor] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: paths.distrosDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var instances: [InstalledInstanceDescriptor] = []
        for item in contents {
            guard (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            let name = item.lastPathComponent
            if name == "default" {
                continue
            }
            if !includeReserved, isReservedInternalInstanceName(name) {
                continue
            }
            let diskPath = paths.distroDiskFile(named: name)
            let metadataPath = paths.distroMetadataFile(named: name)

            var createdAt: Int64?
            if let metadata = try? readJSON(DistributionInstanceMetadata.self, from: metadataPath) {
                createdAt = metadata.createdAtEpochMs
            }

            let baseDiskPath = paths.distroBaseDiskFile(named: name)
            let hasDisk = fileManager.fileExists(atPath: diskPath.path) || fileManager.fileExists(atPath: baseDiskPath.path)
            instances.append(
                InstalledInstanceDescriptor(name: name, hasDisk: hasDisk, createdAtEpochMs: createdAt)
            )
        }
        return instances.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func instanceExists(named rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        return installedInstances(includeReserved: true).contains { $0.name == name && $0.hasDisk }
    }

    func runtimeMetadataURL(explicitInstanceName: String?, defaultInstanceName: String?) throws -> URL {
        if let explicit = explicitInstanceName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            guard let metadata = runtimeMetadataURLIfBootable(instanceName: explicit) else {
                throw MSLRuntimeError("instance '\(explicit)' not found. use `msl list` to inspect installed instances.")
            }
            return metadata
        }

        if let configured = defaultInstanceName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty,
           let metadata = runtimeMetadataURLIfBootable(instanceName: configured) {
            return metadata
        }

        if let firstAvailable = installedInstances().first(where: { $0.hasDisk && !isReservedInternalInstanceName($0.name) }) {
            return paths.distroMetadataFile(named: firstAvailable.name)
        }

        throw MSLRuntimeError(
            "no bootable instance found. run `msl install --list` and install one with `msl install <distribution>`; use `msl list` to inspect installed instances."
        )
    }

    func runtimeMetadataURL(defaultInstanceName: String?) throws -> URL {
        try runtimeMetadataURL(explicitInstanceName: nil, defaultInstanceName: defaultInstanceName)
    }

    private func runtimeMetadataURLIfBootable(instanceName: String) -> URL? {
        let metadata = paths.distroMetadataFile(named: instanceName)
        let disk = paths.distroDiskFile(named: instanceName)
        let baseDisk = paths.distroBaseDiskFile(named: instanceName)
        guard fileManager.fileExists(atPath: disk.path) || fileManager.fileExists(atPath: baseDisk.path) else {
            return nil
        }
        return metadata
    }

    func isReservedInternalInstanceName(_ name: String) -> Bool {
        Self.reservedInternalInstanceNames.contains(name)
    }

    private func defaultBootstrapDiskSizeGB(for instanceName: String) -> Int {
        if instanceName == "_imagewriter" {
            return Self.defaultInternalImagewriterBootstrapDiskSizeGB
        }
        return Self.defaultBootstrapDiskSizeGB
    }

    @discardableResult
    func uninstallInstance(name rawName: String, keepCache: Bool) throws -> DistributionUninstallResult {
        try migrateLegacyRootfsCacheIfNeeded()
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw MSLRuntimeError("instance name is required")
        }

        let instanceDir = paths.distroDirectory(named: name)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: instanceDir.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MSLRuntimeError("instance '\(name)' not found")
        }

        let source = try loadInstanceSourceRecord(name: name)
        let cacheDir = source.flatMap { resolveCacheDirectory(for: $0) }

        try fileManager.removeItem(at: instanceDir)

        var removedCachePath: String?
        var keptCachePath: String?
        if let cacheDir {
            if keepCache {
                keptCachePath = cacheDir.path
            } else if fileManager.fileExists(atPath: cacheDir.path) {
                try fileManager.removeItem(at: cacheDir)
                removedCachePath = cacheDir.path
            }
        }

        logger.log("instance_uninstalled", fields: [
            "name": name,
            "removed_cache": removedCachePath ?? "",
            "kept_cache": keptCachePath ?? ""
        ])

        return DistributionUninstallResult(
            name: name,
            removedInstancePath: instanceDir.path,
            removedCachePath: removedCachePath,
            keptCachePath: keptCachePath
        )
    }

    @discardableResult
    func fetch(
        targetAlias: String?,
        localFilePath: String?,
        containerImageRef: String? = nil,
        force: Bool
    ) throws -> DistributionVerifiedRecord {
        let source = try resolveSource(
            targetAlias: targetAlias,
            localFilePath: localFilePath,
            containerImageRef: containerImageRef
        )
        switch source {
        case .manifest(let entry):
            return try fetchManifestEntry(entry, force: force)
        case .localFile(let url):
            return try cacheLocalFile(url, force: force)
        case .containerRemote:
            throw MSLRuntimeError("cache fetch does not support --from-container")
        case .containerRuntime:
            throw MSLRuntimeError("cache fetch does not support synthetic container-runtime")
        }
    }

    @discardableResult
    func createImage(
        name rawName: String,
        targetAlias: String?,
        localFilePath: String?,
        rebuild: Bool,
        diskSizeGB: Int?
    ) throws -> URL {
        try migrateLegacyRootfsCacheIfNeeded()
        let name = try validateInstanceName(rawName)
        emitStatus("install: preparing instance '\(name)'")
        let source = try resolveSource(targetAlias: targetAlias, localFilePath: localFilePath, containerImageRef: nil)
        emitStatus("install: fetching rootfs archive")
        let verified = try fetch(targetAlias: targetAlias, localFilePath: localFilePath, containerImageRef: nil, force: false)

        try ensureDir(paths.appSupport)
        try ensureDir(paths.cacheDir)
        try ensureDir(paths.cacheStagingDir)
        try ensureDir(paths.distrosDir)

        let distroDir = paths.distroDirectory(named: name)
        let diskFile = paths.distroDiskFile(named: name)
        let sourceFile = paths.distroSourceFile(named: name)
        let metadataFile = paths.distroMetadataFile(named: name)

        if fileManager.fileExists(atPath: diskFile.path), !rebuild {
            logger.log("image_create_skipped_existing", fields: ["name": name, "disk": diskFile.path])
            emitStatus("install: image already exists, skipping build")
            return distroDir
        }

        if fileManager.fileExists(atPath: distroDir.path), rebuild {
            try fileManager.removeItem(at: distroDir)
        }
        try ensureDir(distroDir)

        let stagingID = UUID().uuidString
        let stagingDir = paths.cacheStagingDir.appendingPathComponent(stagingID, isDirectory: true)
        let rootfsDir = stagingDir.appendingPathComponent("rootfs", isDirectory: true)
        try ensureDir(stagingDir)
        try ensureDir(rootfsDir)

        defer { try? fileManager.removeItem(at: stagingDir) }

        let tarballURL = URL(fileURLWithPath: verified.tarballPath)
        emitStatus("install: validating archive entries")
        try validateTarArchiveEntries(tarballURL)
        emitStatus("install: extracting rootfs")
        try extractTarArchive(tarballURL, to: rootfsDir)
        emitStatus("install: injecting msl-init bootloader")
        let runtimeProfile = initialRuntimeProfile(for: source, instanceName: name)
        try stageInitBinary(intoRootfs: rootfsDir, runtimeProfile: runtimeProfile)

        emitStatus("install: creating ext4 disk image")
        try buildExt4Disk(
            from: rootfsDir,
            sourceArchive: tarballURL,
            outputDisk: diskFile,
            diskSizeGB: diskSizeGB ?? defaultBootstrapDiskSizeGB(for: name)
        )

        let sourceRecord: DistributionSourceRecord
        switch source {
        case .manifest(let entry):
            sourceRecord = DistributionSourceRecord(
                sourceType: "manifest",
                distro: entry.distro,
                version: entry.version,
                arch: entry.arch,
                manifestId: entry.id,
                localPath: nil,
                tarballFileName: tarballURL.lastPathComponent,
                sha256: verified.sha256,
                verifiedAtEpochMs: verified.verifiedAtEpochMs
            )
        case .localFile(let url):
            sourceRecord = DistributionSourceRecord(
                sourceType: "local",
                distro: nil,
                version: nil,
                arch: nil,
                manifestId: nil,
                localPath: url.path,
                tarballFileName: tarballURL.lastPathComponent,
                sha256: verified.sha256,
                verifiedAtEpochMs: verified.verifiedAtEpochMs
            )
        case .containerRemote:
            throw MSLRuntimeError("container sources are not supported for bootstrap installs")
        case .containerRuntime:
            throw MSLRuntimeError("container-runtime is not supported for bootstrap installs")
        }

        let defaultKernelProfileRef = try? DefaultInstanceStore(paths: paths, fileManager: fileManager).loadDefaultKernelProfileRef()
        let env = ProcessInfo.processInfo.environment
        let envKernelRaw = env["MSL_KERNEL_PROFILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let envKernelProfileRef = (envKernelRaw?.isEmpty == false) ? envKernelRaw : nil
        let kernelProfileRef = envKernelProfileRef ?? defaultKernelProfileRef ?? "slim"
        let compressionPolicy = try resolveCompressionPolicyForInstall()
        let initialPolicy = initialUserConvergencePolicy(for: source)
        let initialCacheSharing = initialCacheSharingPolicy(for: source)

        let metadata = DistributionInstanceMetadata(
            name: name,
            distroFamily: sourceRecord.distro ?? inferDistroFamily(from: sourceRecord.manifestId),
            createdAtEpochMs: nowEpochMs(),
            bootstrap: DistributionInstanceMetadata.PrivilegeBootstrap(
                firstBootPending: true,
                privilegeBootstrapVersion: 1,
                lastResult: "pending",
                lastBootstrapAtEpochMs: nil
            ),
            user: DistributionInstanceMetadata.UserSnapshot(
                name: resolveDefaultRuntimeUserName(),
                uid: Int(getuid()),
                gid: Int(getgid()),
                groups: [initialPolicy.adminGroup]
            ),
            source: sourceRecord,
            diskPath: diskFile.path,
            kernelProfileRef: kernelProfileRef,
            runtimeProfile: runtimeProfile,
            userConvergencePolicy: initialPolicy,
            workspacePolicy: initialWorkspacePolicy(),
            compressionPolicy: compressionPolicy,
            networkPolicy: initialNetworkPolicy(),
            cacheSharing: initialCacheSharing,
            tmpStorage: DistributionInstanceMetadata.defaultTmpStoragePolicy(forNewInstanceNamed: name)
        )
        try writeJSON(sourceRecord, to: sourceFile)
        try writeJSON(metadata, to: metadataFile)

        logger.log("image_create_completed", fields: [
            "name": name,
            "disk": diskFile.path,
            "compression_policy_count": String(compressionPolicy.pathPolicies.count)
        ])
        emitStatus("install: image ready")
        return distroDir
    }

    @discardableResult
    func createImageWithImagewriter(
        name rawName: String,
        targetAlias: String?,
        localFilePath: String?,
        containerImageRef: String? = nil,
        containerEntrypointOverride: [String]? = nil,
        rebuild: Bool,
        diskSizeGB: Int?,
        mslExecutablePath: String
    ) throws -> URL {
        try migrateLegacyRootfsCacheIfNeeded()
        let name = try validateInstanceName(rawName)
        emitStatus("install: preparing instance '\(name)'")

        try ensureDir(paths.appSupport)
        try ensureDir(paths.cacheDir)
        try ensureDir(paths.cacheStagingDir)
        try ensureDir(paths.distrosDir)

        let distroDir = paths.distroDirectory(named: name)
        let diskFile = paths.distroDiskFile(named: name)
        let existingPrimaryDiskFile = targetAlias == "container-runtime" ? paths.distroBaseDiskFile(named: name) : diskFile
        let sourceFile = paths.distroSourceFile(named: name)
        let metadataFile = paths.distroMetadataFile(named: name)

        if fileManager.fileExists(atPath: existingPrimaryDiskFile.path), !rebuild {
            logger.log("image_create_skipped_existing", fields: ["name": name, "disk": existingPrimaryDiskFile.path])
            emitStatus("install: image already exists, skipping build")
            return distroDir
        }

        if fileManager.fileExists(atPath: distroDir.path), rebuild {
            try fileManager.removeItem(at: distroDir)
        }
        try ensureDir(distroDir)
        var shouldCleanupDistroDirOnFailure = true
        var compressionPolicyCount = 0
        var didRunImagewriterBuild = false
        let imagewriterInstanceName = resolveImagewriterInstanceName()
        defer {
            if didRunImagewriterBuild {
                stopImagewriterInstance(
                    mslExecutablePath: mslExecutablePath,
                    instanceName: imagewriterInstanceName
                )
            }
        }

        do {
            let materialized = try materializeRootFS(
                targetAlias: targetAlias,
                localFilePath: localFilePath,
                containerImageRef: containerImageRef,
                containerEntrypointOverride: containerEntrypointOverride,
                instanceName: name
            )
            defer { try? fileManager.removeItem(at: materialized.cleanupRoot) }

            let imagewriterScript = try resolveImagewriterBuildScriptPath(mslExecutablePath: mslExecutablePath)
            let requestedSizeGB = diskSizeGB ?? Self.defaultImagewriterDiskSizeGB
            let requestedSizeMB = max(1, requestedSizeGB) * 1024
            let initBinaryPath = try resolveImagewriterBootloaderBinaryPath()
            let useReadonlyBaseCowState = materialized.sourceRecord.sourceType == "container-runtime"
            let earlyInitBinaryPath = useReadonlyBaseCowState ? try resolveImagewriterEarlyInitBinaryPath() : nil
            if useReadonlyBaseCowState {
                guard let rootfsDir = materialized.rootfsDir else {
                    throw MSLRuntimeError("container-runtime COW build requires a staged rootfs directory")
                }
                try installEarlyInitIntoRootfs(
                    rootfsDir: rootfsDir,
                    earlyInitBinaryPath: earlyInitBinaryPath
                )
            }
            let baseDiskFile = useReadonlyBaseCowState ? paths.distroBaseDiskFile(named: name) : diskFile
            let stateDiskFile = useReadonlyBaseCowState ? paths.distroStateDiskFile(named: name) : nil
            let stateTemplateDiskFile = useReadonlyBaseCowState ? paths.distroStateTemplateDiskFile(named: name) : nil
            let runtimeSummaryURL = materialized.cleanupRoot.appendingPathComponent("container-runtime-summary.json", isDirectory: false)
            let extraGuestFilesBundleURL = try createImagewriterExtraFilesBundle(
                for: materialized,
                cleanupRoot: materialized.cleanupRoot
            )

            emitStatus(useReadonlyBaseCowState
                ? "install: creating readonly EROFS base and btrfs state images via imagewriter"
                : "install: creating btrfs disk image via imagewriter")
            didRunImagewriterBuild = true
            let rootfsTarballPath = imagewriterRootFSTarballPath(for: materialized)
            let rootfsDirectoryPath = imagewriterRootFSDirectoryPath(for: materialized)
            try runImagewriterBuild(
                scriptPath: imagewriterScript,
                mslExecutablePath: mslExecutablePath,
                rootfsTarballPath: rootfsTarballPath,
                rootfsDirectoryPath: rootfsDirectoryPath,
                ociLayoutDirectoryPath: materialized.ociLayoutDir?.path,
                outputDiskPath: baseDiskFile.path,
                outputStateDiskPath: stateDiskFile?.path,
                outputStateTemplateDiskPath: stateTemplateDiskFile?.path,
                sizeMB: requestedSizeMB,
                initBinaryPath: initBinaryPath,
                earlyInitBinaryPath: earlyInitBinaryPath,
                imageFS: useReadonlyBaseCowState ? "erofs" : "btrfs",
                imagewriterPackages: materialized.imagewriterPackages,
                imagewriterRootFSPackages: materialized.imagewriterRootFSPackages,
                extraGuestFilesBundlePath: extraGuestFilesBundleURL?.path,
                runtimeValidationSummaryPath: materialized.ociLayoutDir == nil ? nil : runtimeSummaryURL.path,
                requestedDefaultExec: materialized.defaultExec,
                source: materialized.source
            )
            var runtimeValidation = try resolveRuntimeValidationSummary(
                for: materialized,
                runtimeSummaryURL: runtimeSummaryURL
            )
            if runtimeValidation.resolvedDefaultExec?.source == nil,
               let source = materialized.defaultExec?.source,
               runtimeValidation.resolvedDefaultExec != nil {
                runtimeValidation.resolvedDefaultExec?.source = source
            }

            let defaultKernelProfileRef = try? DefaultInstanceStore(paths: paths, fileManager: fileManager).loadDefaultKernelProfileRef()
            let env = ProcessInfo.processInfo.environment
            let envKernelRaw = env["MSL_KERNEL_PROFILE"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let envKernelProfileRef = (envKernelRaw?.isEmpty == false) ? envKernelRaw : nil
            let kernelProfileRef = envKernelProfileRef ?? defaultKernelProfileRef ?? "slim"
            let compressionPolicy = try resolveCompressionPolicyForInstall()
            compressionPolicyCount = compressionPolicy.pathPolicies.count
            let initialPolicy = initialUserConvergencePolicy(for: materialized.source)
            let initialCacheSharing = initialCacheSharingPolicy(for: materialized.source)
            let runtimeProfile = initialRuntimeProfile(for: materialized.source, instanceName: name)

            let metadata = DistributionInstanceMetadata(
                name: name,
                distroFamily: materialized.sourceRecord.distro ?? inferDistroFamily(from: materialized.sourceRecord.manifestId),
                createdAtEpochMs: nowEpochMs(),
                bootstrap: DistributionInstanceMetadata.PrivilegeBootstrap(
                    firstBootPending: true,
                    privilegeBootstrapVersion: 1,
                    lastResult: "pending",
                    lastBootstrapAtEpochMs: nil
                ),
                user: DistributionInstanceMetadata.UserSnapshot(
                    name: resolveDefaultRuntimeUserName(),
                    uid: Int(getuid()),
                    gid: Int(getgid()),
                    groups: [initialPolicy.adminGroup]
                ),
                source: materialized.sourceRecord,
                diskPath: diskFile.path,
                baseDiskPath: useReadonlyBaseCowState ? baseDiskFile.path : nil,
                stateDiskPath: stateDiskFile?.path,
                rootMode: useReadonlyBaseCowState ? .readonlyBaseCowState : nil,
                kernelProfileRef: kernelProfileRef,
                runtimeProfile: runtimeProfile,
                userConvergencePolicy: initialPolicy,
                workspacePolicy: initialWorkspacePolicy(),
                compressionPolicy: compressionPolicy,
                networkPolicy: initialNetworkPolicy(),
                cacheSharing: initialCacheSharing,
                tmpStorage: DistributionInstanceMetadata.defaultTmpStoragePolicy(forNewInstanceNamed: name),
                defaultExec: runtimeValidation.resolvedDefaultExec,
                shellAvailable: runtimeValidation.shellAvailable,
                startupMode: resolveStartupMode(
                    source: materialized.sourceRecord,
                    shellAvailable: runtimeValidation.shellAvailable
                ),
                workloadKind: resolveWorkloadKind(source: materialized.sourceRecord)
            )
            try writeJSON(materialized.sourceRecord, to: sourceFile)
            try writeJSON(metadata, to: metadataFile)
            shouldCleanupDistroDirOnFailure = false
        } catch {
            if shouldCleanupDistroDirOnFailure, fileManager.fileExists(atPath: distroDir.path) {
                try? fileManager.removeItem(at: distroDir)
            }
            throw error
        }

        logger.log("image_create_completed", fields: [
            "name": name,
            "disk": diskFile.path,
            "compression_policy_count": String(compressionPolicyCount)
        ])
        emitStatus("install: image ready")
        return distroDir
    }

    private func imagewriterRootFSTarballPath(for materialized: RootFSMaterializationResult) -> String? {
        switch materialized.source {
        case .manifest, .localFile:
            return materialized.sourceArchivePath
        case .containerRemote, .containerRuntime:
            return nil
        }
    }

    private func imagewriterRootFSDirectoryPath(for materialized: RootFSMaterializationResult) -> String? {
        switch materialized.source {
        case .containerRuntime:
            return materialized.rootfsDir?.path
        case .manifest, .localFile, .containerRemote:
            return nil
        }
    }

    @discardableResult
    func createImageFromRaw(
        name rawName: String,
        rawDiskPath: String,
        rebuild: Bool
    ) throws -> URL {
        try migrateLegacyRootfsCacheIfNeeded()
        let name = try validateInstanceName(rawName)
        let rawURL = URL(fileURLWithPath: rawDiskPath)
        guard fileManager.fileExists(atPath: rawURL.path) else {
            throw MSLRuntimeError("raw disk not found: \(rawURL.path)")
        }

        emitStatus("install: preparing instance '\(name)' from raw disk")
        try ensureDir(paths.appSupport)
        try ensureDir(paths.distrosDir)

        let distroDir = paths.distroDirectory(named: name)
        let diskFile = paths.distroDiskFile(named: name)
        let sourceFile = paths.distroSourceFile(named: name)
        let metadataFile = paths.distroMetadataFile(named: name)

        if fileManager.fileExists(atPath: diskFile.path), !rebuild {
            logger.log("image_create_skipped_existing", fields: ["name": name, "disk": diskFile.path])
            emitStatus("install: image already exists, skipping build")
            return distroDir
        }

        if fileManager.fileExists(atPath: distroDir.path), rebuild {
            try fileManager.removeItem(at: distroDir)
        }
        try ensureDir(distroDir)
        if fileManager.fileExists(atPath: diskFile.path) {
            try fileManager.removeItem(at: diskFile)
        }

        emitStatus("install: importing raw disk")
        try fileManager.copyItem(at: rawURL, to: diskFile)

        let sha = try computeSHA256(fileAt: rawURL)
        let sourceRecord = DistributionSourceRecord(
            sourceType: "local-raw",
            distro: nil,
            version: nil,
            arch: nil,
            manifestId: nil,
            localPath: rawURL.path,
            tarballFileName: rawURL.lastPathComponent,
            sha256: sha,
            verifiedAtEpochMs: nowEpochMs()
        )

        let defaultKernelProfileRef = try? DefaultInstanceStore(paths: paths, fileManager: fileManager).loadDefaultKernelProfileRef()
        let env = ProcessInfo.processInfo.environment
        let envKernelRaw = env["MSL_KERNEL_PROFILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let envKernelProfileRef = (envKernelRaw?.isEmpty == false) ? envKernelRaw : nil
        let kernelProfileRef = envKernelProfileRef ?? defaultKernelProfileRef ?? "slim"
        let compressionPolicy = try resolveCompressionPolicyForInstall()
        let localSource = DistributionSourceSelection.localFile(rawURL)
        let initialPolicy = initialUserConvergencePolicy(for: localSource)
        let initialCacheSharing = initialCacheSharingPolicy(for: localSource)
        let runtimeProfile = initialRuntimeProfile(for: localSource, instanceName: name)

        let metadata = DistributionInstanceMetadata(
            name: name,
            distroFamily: nil,
            createdAtEpochMs: nowEpochMs(),
            bootstrap: DistributionInstanceMetadata.PrivilegeBootstrap(
                firstBootPending: true,
                privilegeBootstrapVersion: 1,
                lastResult: "pending",
                lastBootstrapAtEpochMs: nil
            ),
            user: DistributionInstanceMetadata.UserSnapshot(
                name: resolveDefaultRuntimeUserName(),
                uid: Int(getuid()),
                gid: Int(getgid()),
                groups: [initialPolicy.adminGroup]
            ),
            source: sourceRecord,
            diskPath: diskFile.path,
            kernelProfileRef: kernelProfileRef,
            runtimeProfile: runtimeProfile,
            userConvergencePolicy: initialPolicy,
            workspacePolicy: initialWorkspacePolicy(),
            compressionPolicy: compressionPolicy,
            networkPolicy: initialNetworkPolicy(),
            cacheSharing: initialCacheSharing,
            tmpStorage: DistributionInstanceMetadata.defaultTmpStoragePolicy(forNewInstanceNamed: name)
        )
        try writeJSON(sourceRecord, to: sourceFile)
        try writeJSON(metadata, to: metadataFile)

        logger.log("image_create_completed", fields: [
            "name": name,
            "disk": diskFile.path,
            "source_type": "local-raw",
            "compression_policy_count": String(compressionPolicy.pathPolicies.count)
        ])
        emitStatus("install: image ready")
        return distroDir
    }

    private func materializeRootFS(
        targetAlias: String?,
        localFilePath: String?,
        containerImageRef: String?,
        containerEntrypointOverride: [String]? = nil,
        instanceName: String
    ) throws -> RootFSMaterializationResult {
        let source = try resolveSource(
            targetAlias: targetAlias,
            localFilePath: localFilePath,
            containerImageRef: containerImageRef
        )
        let stagingRoot = paths.cacheStagingDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let rootfsDir = stagingRoot.appendingPathComponent("rootfs", isDirectory: true)
        try ensureDir(stagingRoot)
        try ensureDir(rootfsDir)

        switch source {
        case .manifest(let entry):
            emitStatus("install: fetching rootfs archive")
            let verified = try fetchManifestEntry(entry, force: false)
            let tarballURL = URL(fileURLWithPath: verified.tarballPath)
            emitStatus("install: validating archive entries")
            try validateTarArchiveEntries(tarballURL)
            emitStatus("install: extracting rootfs")
            try extractTarArchive(tarballURL, to: rootfsDir)
            try validateRuntimeShell(in: rootfsDir)
            return RootFSMaterializationResult(
                source: source,
                sourceRecord: DistributionSourceRecord(
                    sourceType: "manifest",
                    distro: entry.distro,
                    version: entry.version,
                    arch: entry.arch,
                    manifestId: entry.id,
                    localPath: nil,
                    tarballFileName: tarballURL.lastPathComponent,
                    sha256: verified.sha256,
                    verifiedAtEpochMs: verified.verifiedAtEpochMs
                ),
                rootfsDir: rootfsDir,
                ociLayoutDir: nil,
                defaultExec: nil,
                shellAvailable: true,
                imagewriterPackages: nil,
                imagewriterRootFSPackages: Self.rootFSPackages(forManifestEntry: entry),
                sourceArchivePath: tarballURL.path,
                cleanupRoot: stagingRoot
            )
        case .localFile(let url):
            emitStatus("install: caching local rootfs archive")
            let verified = try cacheLocalFile(url, force: false)
            let tarballURL = URL(fileURLWithPath: verified.tarballPath)
            emitStatus("install: validating archive entries")
            try validateTarArchiveEntries(tarballURL)
            emitStatus("install: extracting rootfs")
            try extractTarArchive(tarballURL, to: rootfsDir)
            try validateRuntimeShell(in: rootfsDir)
            return RootFSMaterializationResult(
                source: source,
                sourceRecord: DistributionSourceRecord(
                    sourceType: "local",
                    distro: nil,
                    version: nil,
                    arch: nil,
                    manifestId: nil,
                    localPath: url.path,
                    tarballFileName: tarballURL.lastPathComponent,
                    sha256: verified.sha256,
                    verifiedAtEpochMs: verified.verifiedAtEpochMs
                ),
                rootfsDir: rootfsDir,
                ociLayoutDir: nil,
                defaultExec: nil,
                shellAvailable: true,
                imagewriterPackages: nil,
                imagewriterRootFSPackages: "",
                sourceArchivePath: tarballURL.path,
                cleanupRoot: stagingRoot
            )
        case .containerRemote(let reference):
            emitStatus("install: resolving container image")
            let resolved = try resolveContainerImage(reference)
            emitStatus("install: fetching container layers")
            let (tarballFileName, ociLayoutDir) = try materializeContainerRootFS(
                resolved,
                cleanupRoot: stagingRoot
            )
            return RootFSMaterializationResult(
                source: source,
                sourceRecord: DistributionSourceRecord(
                    sourceType: "container-remote",
                    distro: nil,
                    version: nil,
                    arch: "arm64",
                    manifestId: nil,
                    localPath: nil,
                    tarballFileName: tarballFileName,
                    sha256: resolved.digest,
                    verifiedAtEpochMs: nowEpochMs(),
                    imageRef: reference.original,
                    resolvedReference: resolved.resolvedReference,
                    registry: reference.registry,
                    repository: reference.repository,
                    tag: reference.tag,
                    digest: resolved.digest,
                    platform: resolved.platform
                ),
                rootfsDir: nil,
                ociLayoutDir: ociLayoutDir,
                defaultExec: initialContainerDefaultExec(
                    for: resolved,
                    overrideArgv: containerEntrypointOverride
                ),
                shellAvailable: nil,
                imagewriterPackages: nil,
                imagewriterRootFSPackages: "",
                sourceArchivePath: nil,
                cleanupRoot: stagingRoot
            )
        case .containerRuntime:
            guard let alpineEntry = manifestStore.resolve(alias: "alpine") else {
                throw MSLRuntimeError("embedded manifest is missing alpine base for container-runtime")
            }
            try manifestStore.validate(alpineEntry)
            emitStatus("install: fetching runtime base rootfs")
            let verified = try fetchManifestEntry(alpineEntry, force: false)
            let tarballURL = URL(fileURLWithPath: verified.tarballPath)
            emitStatus("install: validating runtime base archive")
            try validateTarArchiveEntries(tarballURL)
            emitStatus("install: extracting runtime base rootfs")
            try extractTarArchive(tarballURL, to: rootfsDir)
            try normalizeContainerRootFSPermissions(rootfsDir: rootfsDir)
            try configureContainerRuntimeRootFS(rootfsDir: rootfsDir)
            return RootFSMaterializationResult(
                source: source,
                sourceRecord: DistributionSourceRecord(
                    sourceType: "container-runtime",
                    distro: "alpine",
                    version: alpineEntry.version,
                    arch: alpineEntry.arch,
                    manifestId: alpineEntry.id,
                    localPath: nil,
                    tarballFileName: tarballURL.lastPathComponent,
                    sha256: verified.sha256,
                    verifiedAtEpochMs: verified.verifiedAtEpochMs
                ),
                rootfsDir: rootfsDir,
                ociLayoutDir: nil,
                defaultExec: DistributionInstanceMetadata.DefaultExec(
                    argv: ["/usr/local/bin/nerdctl", "help"],
                    env: [
                        "CONTAINERD_ADDRESS=/run/containerd/containerd.sock",
                        "BUILDKIT_HOST=unix:///run/buildkit/buildkitd.sock"
                    ],
                    source: "runtime-default"
                ),
                shellAvailable: true,
                imagewriterPackages: nil,
                imagewriterRootFSPackages: Self.containerRuntimeImagewriterPackages,
                sourceArchivePath: tarballURL.path,
                cleanupRoot: stagingRoot
            )
        }
    }

    private static func rootFSPackages(forManifestEntry entry: DistributionManifestEntry) -> String {
        entry.distro.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "alpine"
            ? alpineDistributionRootFSPackages
            : ""
    }

    private func validateRuntimeShell(in rootfsDir: URL) throws {
        let candidates = [
            "bin/sh",
            "bin/bash",
            "bin/ash"
        ]
        for candidate in candidates {
            if rootfsPathExists(candidate, in: rootfsDir) {
                return
            }
        }
        throw MSLRuntimeError("rootfs is not supported: no usable shell found (/bin/sh, /bin/bash, /bin/ash)")
    }

    private func rootfsPathExists(_ relativePath: String, in rootfsDir: URL, depth: Int = 0) -> Bool {
        guard depth < 16 else { return false }
        let path = rootfsDir.appendingPathComponent(relativePath, isDirectory: false)
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: path.path) else {
            return fileManager.fileExists(atPath: path.path)
        }
        let nextRelativePath: String
        if destination.hasPrefix("/") {
            nextRelativePath = String(destination.drop(while: { $0 == "/" }))
        } else {
            let parent = (relativePath as NSString).deletingLastPathComponent
            nextRelativePath = (parent as NSString).appendingPathComponent(destination)
        }
        let normalized = (nextRelativePath as NSString).standardizingPath
        let clean = normalized.hasPrefix("/") ? String(normalized.dropFirst()) : normalized
        guard !clean.isEmpty, !clean.hasPrefix("../"), clean != ".." else {
            return false
        }
        return rootfsPathExists(clean, in: rootfsDir, depth: depth + 1)
    }

    private func initialContainerDefaultExec(
        for resolved: ResolvedContainerImage,
        overrideArgv: [String]? = nil
    ) -> DistributionInstanceMetadata.DefaultExec? {
        let cleanOverride = (overrideArgv ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let argv = cleanOverride.isEmpty
            ? mergedContainerDefaultCommand(entrypoint: resolved.entrypoint, cmd: resolved.cmd)
            : cleanOverride
        guard let argv, !argv.isEmpty else {
            return nil
        }
        return DistributionInstanceMetadata.DefaultExec(
            argv: argv,
            workingDir: resolved.workingDir,
            user: resolved.user,
            env: resolved.env,
            source: cleanOverride.isEmpty ? "image-config" : "install-override"
        )
    }

    private func mergedContainerDefaultCommand(entrypoint: [String]?, cmd: [String]?) -> [String]? {
        let cleanEntrypoint = (entrypoint ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let cleanCmd = (cmd ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !cleanEntrypoint.isEmpty {
            return cleanEntrypoint + cleanCmd
        }
        if !cleanCmd.isEmpty {
            return cleanCmd
        }
        return nil
    }

    private func resolveRuntimeValidationSummary(
        for materialized: RootFSMaterializationResult,
        runtimeSummaryURL: URL
    ) throws -> ContainerRuntimeValidationSummary {
        if case .containerRuntime = materialized.source {
            return ContainerRuntimeValidationSummary(
                shellAvailable: materialized.shellAvailable ?? true,
                resolvedDefaultExec: materialized.defaultExec
            )
        }
        if let rootfsDir = materialized.rootfsDir {
            try validateRuntimeShell(in: rootfsDir)
            return ContainerRuntimeValidationSummary(
                shellAvailable: true,
                resolvedDefaultExec: nil
            )
        }

        guard materialized.ociLayoutDir != nil else {
            throw MSLRuntimeError("install source did not provide a rootfs or OCI layout")
        }
        guard fileManager.fileExists(atPath: runtimeSummaryURL.path) else {
            throw MSLRuntimeError("container runtime validation summary missing: \(runtimeSummaryURL.path)")
        }
        let summary = try parseContainerRuntimeValidationSummary(from: runtimeSummaryURL)
        if !summary.shellAvailable, summary.resolvedDefaultExec == nil {
            throw MSLRuntimeError("container image is not supported: no usable shell and no resolvable default command")
        }
        return summary
    }

    private func parseContainerRuntimeValidationSummary(from url: URL) throws -> ContainerRuntimeValidationSummary {
        let raw = try String(contentsOf: url, encoding: .utf8)
        var values: [String: String] = [:]
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            values[key] = value
        }

        let shellAvailable = values["SHELL_AVAILABLE"] == "true"
        let argv = decodeBase64Lines(values["DEFAULT_EXEC_ARGV_B64"])
        let env = decodeBase64Lines(values["DEFAULT_EXEC_ENV_B64"])
        let defaultExec: DistributionInstanceMetadata.DefaultExec?
        if let argv, !argv.isEmpty {
            defaultExec = DistributionInstanceMetadata.DefaultExec(
                argv: argv,
                workingDir: values["DEFAULT_EXEC_WORKDIR"].flatMap { $0.isEmpty ? nil : $0 },
                user: values["DEFAULT_EXEC_USER"].flatMap { $0.isEmpty ? nil : $0 },
                env: env ?? []
            )
        } else {
            defaultExec = nil
        }

        return ContainerRuntimeValidationSummary(
            shellAvailable: shellAvailable,
            resolvedDefaultExec: defaultExec
        )
    }

    private func decodeBase64Lines(_ value: String?) -> [String]? {
        guard let value, !value.isEmpty, let data = Data(base64Encoded: value),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        return lines.isEmpty ? nil : lines
    }

    private func createImagewriterExtraFilesBundle(
        for materialized: RootFSMaterializationResult,
        cleanupRoot: URL
    ) throws -> URL? {
        guard materialized.ociLayoutDir != nil else {
            return nil
        }
        let guestUmoci = try resolveBundledContainerToolArtifact(named: "umoci", platform: "linux-arm64")
        let bundleDir = cleanupRoot.appendingPathComponent("imagewriter-extra-files", isDirectory: true)
        let payloadDir = bundleDir.appendingPathComponent("payload", isDirectory: true)
        try ensureDir(payloadDir)

        let umociDestination = payloadDir.appendingPathComponent("umoci", isDirectory: false)
        if fileManager.fileExists(atPath: umociDestination.path) {
            try fileManager.removeItem(at: umociDestination)
        }
        try fileManager.copyItem(at: guestUmoci, to: umociDestination)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: umociDestination.path)

        let manifest = ImagewriterExtraFilesManifest(
            files: [
                ImagewriterExtraFileEntry(
                    sourceRelativePath: "payload/umoci",
                    guestPath: "extras/umoci",
                    mode: "0755"
                )
            ]
        )
        try writeJSON(manifest, to: bundleDir.appendingPathComponent("manifest.json", isDirectory: false))
        return bundleDir
    }

    func readInstanceMetadata(at metadataURL: URL) throws -> DistributionInstanceMetadata {
        try readJSON(DistributionInstanceMetadata.self, from: metadataURL)
    }

    func readOrRebuildInstanceMetadata(at metadataURL: URL) throws -> DistributionInstanceMetadata {
        do {
            var metadata = try readJSON(DistributionInstanceMetadata.self, from: metadataURL)
            var didMutate = false
            if metadata.cacheSharing == nil {
                metadata.cacheSharing = defaultCacheSharingPolicy(
                    distroFamily: metadata.distroFamily
                        ?? metadata.source.distro
                        ?? inferDistroFamily(from: metadata.source.manifestId)
                )
                didMutate = true
                logger.log("cache_sharing_backfilled", fields: [
                    "instance": metadata.name,
                    "metadata": metadataURL.path
                ])
            }
            if metadata.runtimeProfile == nil {
                metadata.runtimeProfile = backfillRuntimeProfile(
                    metadata: metadata,
                    preferServiceManaged: false
                )
                didMutate = true
                logger.log("runtime_profile_backfilled", fields: [
                    "instance": metadata.name,
                    "metadata": metadataURL.path,
                    "init_mode": metadata.runtimeProfile?.initMode ?? "-",
                    "service_manager": metadata.runtimeProfile?.serviceManager ?? "-"
                ])
            } else if let manifestDefaultMode = resolveManifestDefaultInitMode(for: metadata.source),
                      manifestDefaultMode == "direct-init",
                      metadata.runtimeProfile?.initMode != manifestDefaultMode {
                metadata.runtimeProfile?.initMode = manifestDefaultMode
                didMutate = true
                logger.log("runtime_profile_mode_overridden_by_manifest", fields: [
                    "instance": metadata.name,
                    "metadata": metadataURL.path,
                    "init_mode": manifestDefaultMode
                ])
            }
            let validatedTmpStorage = try metadata.resolveValidatedTmpStoragePolicy(
                applyEnvironmentOverride: false
            )
            if let existing = metadata.tmpStorage {
                if existing.mode != validatedTmpStorage.mode ||
                    existing.sizeMiB != validatedTmpStorage.sizeMiB ||
                    existing.resetOnStop != validatedTmpStorage.resetOnStop {
                    metadata.tmpStorage = validatedTmpStorage
                    didMutate = true
                    logger.log("tmp_storage_policy_normalized", fields: [
                        "instance": metadata.name,
                        "metadata": metadataURL.path,
                        "mode": validatedTmpStorage.mode,
                        "size_mib": String(validatedTmpStorage.sizeMiB),
                        "reset_on_stop": validatedTmpStorage.resetOnStop ? "true" : "false"
                    ])
                }
            }
            if metadata.startupMode == nil {
                metadata.startupMode = resolveStartupMode(
                    source: metadata.source,
                    shellAvailable: metadata.shellAvailable ?? true
                )
                didMutate = true
                logger.log("startup_mode_backfilled", fields: [
                    "instance": metadata.name,
                    "metadata": metadataURL.path,
                    "startup_mode": metadata.startupMode?.rawValue ?? "interactive"
                ])
            }
            if metadata.workloadKind == nil {
                metadata.workloadKind = resolveWorkloadKind(source: metadata.source)
                didMutate = true
                logger.log("workload_kind_backfilled", fields: [
                    "instance": metadata.name,
                    "metadata": metadataURL.path,
                    "workload_kind": metadata.workloadKind?.rawValue ?? "generic"
                ])
            }
            if didMutate {
                try writeJSON(metadata, to: metadataURL)
            }
            return metadata
        } catch let error as MSLRuntimeError {
            throw error
        } catch {
            logger.log("metadata_rebuild_started", fields: [
                "metadata": metadataURL.path,
                "reason": String(describing: error)
            ])
            let rebuilt = try rebuildInstanceMetadata(at: metadataURL)
            logger.log("metadata_rebuild_completed", fields: [
                "metadata": metadataURL.path,
                "instance": rebuilt.name
            ])
            return rebuilt
        }
    }

    private func resolveStartupMode(
        source: DistributionSourceRecord,
        shellAvailable: Bool
    ) -> DistributionInstanceMetadata.StartupMode {
        if source.sourceType == "container-runtime" {
            return .processFirst
        }
        if source.sourceType == "container-remote", shellAvailable == false {
            return .processFirst
        }
        return .interactive
    }

    private func resolveWorkloadKind(
        source: DistributionSourceRecord
    ) -> DistributionInstanceMetadata.WorkloadKind {
        if source.sourceType == "container-runtime" {
            return .containerRuntime
        }
        return .generic
    }

    func writeBootstrapResult(
        metadataURL: URL,
        result: String,
        runtimeUser: RuntimeUserState?,
        fallbackAdminGroup: String?
    ) throws {
        var metadata = try readOrRebuildInstanceMetadata(at: metadataURL)
        var bootstrap = metadata.bootstrap ?? DistributionInstanceMetadata.PrivilegeBootstrap()
        bootstrap.firstBootPending = (result != "success")
        bootstrap.lastResult = result
        bootstrap.lastBootstrapAtEpochMs = nowEpochMs()
        metadata.bootstrap = bootstrap

        if let runtimeUser {
            let groups: [String]
            if let existingGroups = metadata.user?.groups, !existingGroups.isEmpty {
                groups = existingGroups
            } else if let fallbackAdminGroup, !fallbackAdminGroup.isEmpty {
                groups = [fallbackAdminGroup]
            } else {
                groups = []
            }
            metadata.user = DistributionInstanceMetadata.UserSnapshot(
                name: runtimeUser.name,
                uid: runtimeUser.uid,
                gid: runtimeUser.gid,
                groups: groups
            )
        }

        do {
            try writeJSON(metadata, to: metadataURL)
            logger.log("metadata_write_succeeded", fields: [
                "metadata": metadataURL.path,
                "result": result
            ])
        } catch {
            logger.log("metadata_write_failed", fields: [
                "metadata": metadataURL.path,
                "result": result,
                "error": String(describing: error)
            ])
            throw error
        }
    }

    func resolveUserConvergencePolicy(metadataURL: URL) throws -> UserConvergencePolicy {
        var metadata = try readOrRebuildInstanceMetadata(at: metadataURL)
        if let existing = metadata.userConvergencePolicy {
            return try validateUserConvergencePolicy(existing, metadataURL: metadataURL)
        }

        let generated = backfillUserConvergencePolicy(for: metadata)
        let validated = try validateUserConvergencePolicy(generated, metadataURL: metadataURL)
        metadata.userConvergencePolicy = validated
        try writeJSON(metadata, to: metadataURL)
        logger.log("user_policy_backfilled", fields: [
            "instance": metadata.name,
            "metadata": metadataURL.path,
            "template_id": validated.templateId
        ])
        return validated
    }

    internal func resolveSource(
        targetAlias: String?,
        localFilePath: String?,
        containerImageRef: String? = nil
    ) throws -> DistributionSourceSelection {
        if let localFilePath, !localFilePath.isEmpty {
            let local = URL(fileURLWithPath: localFilePath)
            guard fileManager.fileExists(atPath: local.path) else {
                throw MSLRuntimeError("local tarball not found: \(local.path)")
            }
            let fileName = local.lastPathComponent.lowercased()
            if !(fileName.hasSuffix(".tar.xz") || fileName.hasSuffix(".tar.gz")) {
                throw MSLRuntimeError("local tarball must end with .tar.xz or .tar.gz")
            }
            return .localFile(local)
        }

        if let containerImageRef, !containerImageRef.isEmpty {
            return .containerRemote(try parseContainerImageReference(containerImageRef))
        }

        guard let targetAlias, !targetAlias.isEmpty else {
            throw MSLRuntimeError("missing distribution target. use --distro <id>, --file <path>, or --from-container <image-ref>")
        }
        if targetAlias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == Self.containerRuntimeAlias {
            guard allowInternalContainerRuntimeInstallSurface() else {
                throw MSLRuntimeError("container-runtime is internal; use `make build-container-runtime`")
            }
            return .containerRuntime
        }
        guard let entry = manifestStore.resolve(alias: targetAlias) else {
            throw MSLRuntimeError("unsupported distribution '\(targetAlias)'")
        }
        try manifestStore.validate(entry)
        return .manifest(entry)
    }

    internal func parseContainerImageReference(_ raw: String) throws -> ContainerImageReference {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MSLRuntimeError("container image reference must not be empty")
        }
        let digestParts = trimmed.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        let nameAndTag = String(digestParts[0])
        let digest = digestParts.count == 2 ? String(digestParts[1]) : nil

        let slashParts = nameAndTag.split(separator: "/")
        let firstComponent = slashParts.first.map(String.init) ?? ""
        let hasExplicitRegistry = slashParts.count > 1 &&
            (firstComponent.contains(".") || firstComponent.contains(":") || firstComponent == "localhost")

        let registry: String
        let repositoryAndTag: String
        if hasExplicitRegistry {
            registry = firstComponent
            repositoryAndTag = slashParts.dropFirst().joined(separator: "/")
            guard !repositoryAndTag.isEmpty else {
                throw MSLRuntimeError("container image reference is missing repository path: \(trimmed)")
            }
        } else {
            registry = "docker.io"
            let implicitRepository = nameAndTag.contains("/") ? nameAndTag : "library/\(nameAndTag)"
            repositoryAndTag = implicitRepository
        }

        let lastSlash = repositoryAndTag.lastIndex(of: "/")
        let lastColon = repositoryAndTag.lastIndex(of: ":")
        let hasTag = lastColon != nil && (lastSlash == nil || lastColon! > lastSlash!)
        let repository = hasTag ? String(repositoryAndTag[..<lastColon!]) : repositoryAndTag
        let tag = hasTag ? String(repositoryAndTag[repositoryAndTag.index(after: lastColon!)...]) : nil
        guard !repository.isEmpty else {
            throw MSLRuntimeError("container image reference is missing repository path: \(trimmed)")
        }

        let normalizedName = "\(registry)/\(repository)"
        return ContainerImageReference(
            original: trimmed,
            registry: registry,
            repository: repository,
            tag: tag,
            digest: digest,
            normalizedName: normalizedName
        )
    }

    private func resolveContainerImage(_ reference: ContainerImageReference) throws -> ResolvedContainerImage {
        let regctl = try resolveBundledOrInstalledContainerTool("regctl")

        let imageReference = buildContainerReferenceString(reference)
        let result = try process.run(
            regctl,
            [
                "image",
                "inspect",
                "--platform", "linux/arm64",
                imageReference
            ],
            captureOutput: true
        )
        guard result.exitCode == 0 else {
            let detail = result.nonEmptyErrorOutput
            if detail.localizedCaseInsensitiveContains("unauthorized") || detail.localizedCaseInsensitiveContains("authentication") {
                throw MSLRuntimeError("container registry authentication is not supported in v1: \(reference.original)")
            }
            throw MSLRuntimeError("failed to inspect container image \(reference.original): \(detail)")
        }
        guard let data = result.stdout.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MSLRuntimeError("failed to parse regctl inspect output for \(reference.original)")
        }
        let digest = (object["Digest"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let configObject = object["config"] as? [String: Any]
        guard !digest.isEmpty else {
            let headResult = try process.run(
                regctl,
                [
                    "manifest",
                    "head",
                    "--platform", "linux/arm64",
                    imageReference
                ],
                captureOutput: true
            )
            guard headResult.exitCode == 0 else {
                throw MSLRuntimeError("failed to resolve digest for container image \(reference.original): \(headResult.nonEmptyErrorOutput)")
            }
            let headDigest = headResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !headDigest.isEmpty else {
                throw MSLRuntimeError("failed to resolve digest for container image \(reference.original)")
            }
            return ResolvedContainerImage(
                reference: reference,
                resolvedReference: "\(reference.normalizedName)@\(headDigest)",
                digest: headDigest,
                platform: "linux/arm64",
                manifestDigest: headDigest,
                entrypoint: sanitizeContainerStringArray(configObject?["Entrypoint"]),
                cmd: sanitizeContainerStringArray(configObject?["Cmd"]),
                user: sanitizeContainerString(configObject?["User"]),
                workingDir: sanitizeContainerString(configObject?["WorkingDir"]),
                env: sanitizeContainerStringArray(configObject?["Env"]) ?? []
            )
        }
        let architecture = ((object["Architecture"] as? String) ?? "").lowercased()
        let os = ((object["Os"] as? String) ?? "").lowercased()
        guard architecture == "arm64", os == "linux" else {
            throw MSLRuntimeError("container image must resolve to linux/arm64, got \(os)/\(architecture)")
        }
        return ResolvedContainerImage(
            reference: reference,
            resolvedReference: "\(reference.normalizedName)@\(digest)",
            digest: digest,
            platform: "linux/arm64",
            manifestDigest: digest,
            entrypoint: sanitizeContainerStringArray(configObject?["Entrypoint"]),
            cmd: sanitizeContainerStringArray(configObject?["Cmd"]),
            user: sanitizeContainerString(configObject?["User"]),
            workingDir: sanitizeContainerString(configObject?["WorkingDir"]),
            env: sanitizeContainerStringArray(configObject?["Env"]) ?? []
        )
    }

    private func materializeContainerRootFS(
        _ resolved: ResolvedContainerImage,
        cleanupRoot: URL
    ) throws -> (String, URL) {
        let regctl = try resolveBundledOrInstalledContainerTool("regctl")

        let digestKey = sanitizeDigestForPath(resolved.digest)
        let cacheBase = containerCacheBaseDirectory(
            registry: resolved.reference.registry,
            repository: resolved.reference.repository,
            digest: digestKey
        )
        let layoutDir = cacheBase.appendingPathComponent("oci", isDirectory: true)
        try ensureDir(cacheBase)

        if !fileManager.fileExists(atPath: layoutDir.path) {
            try ensureDir(layoutDir)
            let copyResult = try process.run(
                regctl,
                [
                    "image",
                    "copy",
                    "--platform", "linux/arm64",
                    resolved.resolvedReference,
                    "ocidir://\(layoutDir.path):image"
                ],
                captureOutput: true
            )
            guard copyResult.exitCode == 0 else {
                throw MSLRuntimeError("failed to copy container image \(resolved.reference.original): \(copyResult.nonEmptyErrorOutput)")
            }
        }

        let tarballFileName = "\(resolved.reference.repository.replacingOccurrences(of: "/", with: "-"))-\(digestKey).oci"
        let stagedLayoutDir = cleanupRoot.appendingPathComponent("oci-layout", isDirectory: true)
        try ensureDir(stagedLayoutDir)
        try copyDirectoryContents(from: layoutDir, to: stagedLayoutDir)
        return (tarballFileName, stagedLayoutDir)
    }

    private func buildContainerReferenceString(_ reference: ContainerImageReference) -> String {
        var result = reference.normalizedName
        if let digest = reference.digest, !digest.isEmpty {
            result += "@\(digest)"
        } else {
            result += ":\(reference.tag ?? "latest")"
        }
        return result
    }

    func resetWritableState(name rawName: String) throws -> URL {
        let name = try validateInstanceName(rawName)
        let metadataURL = paths.distroMetadataFile(named: name)
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            throw MSLRuntimeError("instance '\(name)' not found")
        }
        let metadata = try readJSON(DistributionInstanceMetadata.self, from: metadataURL)
        guard metadata.resolvedRootMode() == .readonlyBaseCowState else {
            throw MSLRuntimeError("instance '\(name)' does not use readonly-base-cow-state storage")
        }

        let templateURL = paths.distroStateTemplateDiskFile(named: name)
        let stateURL = URL(fileURLWithPath: metadata.stateDiskPath ?? paths.distroStateDiskFile(named: name).path)
        guard fileManager.fileExists(atPath: templateURL.path) else {
            throw MSLRuntimeError("state template image not found for '\(name)': \(templateURL.path). reinstall or rebuild the instance.")
        }

        if fileManager.fileExists(atPath: stateURL.path) {
            try fileManager.removeItem(at: stateURL)
        }
        try fileManager.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try copySparseFile(from: templateURL, to: stateURL)
        logger.log("state_disk_reset", fields: [
            "instance": name,
            "template": templateURL.path,
            "state": stateURL.path
        ])
        return stateURL
    }

    private func copySparseFile(from source: URL, to destination: URL) throws {
        if let cp = process.findExecutable(["cp"]) {
            let result = try process.run(cp, ["--sparse=always", "-f", source.path, destination.path], captureOutput: true)
            if result.exitCode == 0 {
                return
            }
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    private func sanitizeContainerString(_ value: Any?) -> String? {
        guard let value = value as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func sanitizeContainerStringArray(_ value: Any?) -> [String]? {
        guard let values = value as? [String] else {
            return nil
        }
        let cleaned = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return cleaned.isEmpty ? nil : cleaned
    }

    internal func resolveBundledOrInstalledContainerTool(_ name: String) throws -> String {
        if let package = try findBundledContainerToolPackage() {
            return try installBundledContainerTool(named: name, from: package)
        }
        if let staged = try findStagedContainerTool(named: name) {
            return staged
        }
        if let installed = try findInstalledBundledContainerTool(named: name) {
            return installed
        }
        if let pathExecutable = process.findExecutable([name]) {
            return pathExecutable
        }
        throw MSLRuntimeError("container helper not found: \(name). bundled helper missing and PATH fallback was not available")
    }

    private func resolveBundledContainerToolArtifact(named name: String, platform: String) throws -> URL {
        if let package = try findBundledContainerToolPackage(),
           let record = package.manifest.record(named: name, platform: platform) {
            try verifyBundledToolRecord(record, root: package.root, errorContext: "bundled helper checksum mismatch")
            return package.root.appendingPathComponent(record.relativePath, isDirectory: false)
        }

        let manifestURL = paths.bundledContainerToolsStageDir.appendingPathComponent("manifest.json", isDirectory: false)
        if fileManager.fileExists(atPath: manifestURL.path) {
            let manifest = try readJSON(BundledToolManifest.self, from: manifestURL)
            if let record = manifest.record(named: name, platform: platform) {
                try verifyBundledToolRecord(record, root: paths.bundledContainerToolsStageDir, errorContext: "bundled helper checksum mismatch")
                return paths.bundledContainerToolsStageDir.appendingPathComponent(record.relativePath, isDirectory: false)
            }
        }

        throw MSLRuntimeError("bundled helper missing: \(name) for platform \(platform)")
    }

    private func findBundledContainerToolPackage() throws -> (root: URL, manifest: BundledToolManifest)? {
        for candidate in bundledContainerToolCandidateDirectories() {
            let manifestURL = candidate.appendingPathComponent("manifest.json", isDirectory: false)
            guard fileManager.fileExists(atPath: manifestURL.path) else {
                continue
            }
            let manifest = try readJSON(BundledToolManifest.self, from: manifestURL)
            return (candidate, manifest)
        }
        return nil
    }

    private func findStagedContainerTool(named name: String) throws -> String? {
        let manifestURL = paths.bundledContainerToolsStageDir.appendingPathComponent("manifest.json", isDirectory: false)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return nil
        }
        let manifest = try readJSON(BundledToolManifest.self, from: manifestURL)
        guard let record = manifest.record(named: name, platform: "darwin-arm64") else {
            return nil
        }
        try verifyBundledToolRecord(record, root: paths.bundledContainerToolsStageDir, errorContext: "bundled helper checksum mismatch")
        let toolURL = paths.bundledContainerToolsStageDir.appendingPathComponent(record.relativePath, isDirectory: false)
        guard fileManager.isExecutableFile(atPath: toolURL.path) else {
            throw MSLRuntimeError("bundled helper missing: \(name)")
        }
        return toolURL.path
    }

    private func bundledContainerToolCandidateDirectories() -> [URL] {
        var candidates: [URL] = []
        if let override = environment["MSL_BUNDLED_CONTAINER_TOOLS_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override, isDirectory: true))
        }

        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("container-tools", isDirectory: true))
            candidates.append(resourceURL.appendingPathComponent("tools", isDirectory: true))
        }

        let executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0], isDirectory: false)
        let executableDir = executableURL.deletingLastPathComponent()
        candidates.append(executableDir.appendingPathComponent("container-tools", isDirectory: true))
        candidates.append(executableDir.appendingPathComponent("tools", isDirectory: true))
        candidates.append(executableDir.deletingLastPathComponent().appendingPathComponent("container-tools", isDirectory: true))
        candidates.append(executableDir.deletingLastPathComponent().appendingPathComponent("tools", isDirectory: true))

        var unique: [URL] = []
        var seen: Set<String> = []
        for candidate in candidates {
            let standardized = candidate.standardizedFileURL.path
            if seen.insert(standardized).inserted {
                unique.append(candidate)
            }
        }
        return unique
    }

    private func installBundledContainerTool(
        named name: String,
        from package: (root: URL, manifest: BundledToolManifest)
    ) throws -> String {
        let manifest = package.manifest
        let platform = "darwin-arm64"
        let hostTools = manifest.records(platform: platform)
        guard let record = manifest.record(named: name, platform: platform) else {
            throw MSLRuntimeError("bundled helper missing: \(name)")
        }

        for tool in hostTools {
            try verifyBundledToolRecord(tool, root: package.root, errorContext: "bundled helper checksum mismatch")
        }

        let targetDir = paths.bundledContainerToolsDirectory(bundleVersion: manifest.bundleVersion)
        let targetManifestURL = paths.bundledContainerToolsManifestFile(bundleVersion: manifest.bundleVersion)
        if fileManager.fileExists(atPath: targetManifestURL.path) {
            let installedManifest = try readJSON(BundledToolManifest.self, from: targetManifestURL)
            if installedManifest == manifest,
               let installedPath = try installedToolPathIfValid(record, under: targetDir) {
                return installedPath
            }
            try? fileManager.removeItem(at: targetDir)
        }

        do {
            try ensureDir(paths.mslHostContainerToolsDir)
            try ensureDir(targetDir)
            for tool in hostTools {
                let source = package.root.appendingPathComponent(tool.relativePath, isDirectory: false)
                let destination = targetDir.appendingPathComponent(tool.name, isDirectory: false)
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: source, to: destination)
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            }
            let manifestData = try JSONEncoder().encode(manifest)
            try manifestData.write(to: targetManifestURL, options: .atomic)
        } catch {
            throw MSLRuntimeError("bundle extraction failed for container helper \(name): \(error)")
        }

        guard let installedPath = try installedToolPathIfValid(record, under: targetDir) else {
            throw MSLRuntimeError("bundle extraction failed for container helper \(name): installed helper missing after extraction")
        }
        return installedPath
    }

    private func findInstalledBundledContainerTool(named name: String) throws -> String? {
        guard fileManager.fileExists(atPath: paths.mslHostContainerToolsDir.path) else {
            return nil
        }
        let contents = try fileManager.contentsOfDirectory(
            at: paths.mslHostContainerToolsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let sorted = try contents.sorted { lhs, rhs in
            let lhsDate = try lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            let rhsDate = try rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            return lhsDate > rhsDate
        }
        for directory in sorted {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            let manifestURL = directory.appendingPathComponent("manifest.json", isDirectory: false)
            guard fileManager.fileExists(atPath: manifestURL.path) else {
                continue
            }
            let manifest = try readJSON(BundledToolManifest.self, from: manifestURL)
            guard let record = manifest.record(named: name, platform: "darwin-arm64"),
                  let path = try installedToolPathIfValid(record, under: directory) else {
                continue
            }
            return path
        }
        return nil
    }

    private func installedToolPathIfValid(_ record: BundledToolRecord, under directory: URL) throws -> String? {
        let installed = directory.appendingPathComponent(record.name, isDirectory: false)
        guard fileManager.fileExists(atPath: installed.path), fileManager.isExecutableFile(atPath: installed.path) else {
            return nil
        }
        try verifyFileChecksum(installed, expected: record.checksum, errorContext: "bundled helper checksum mismatch")
        return installed.path
    }

    private func verifyBundledToolRecord(_ record: BundledToolRecord, root: URL, errorContext: String) throws {
        let toolURL = root.appendingPathComponent(record.relativePath, isDirectory: false)
        guard fileManager.fileExists(atPath: toolURL.path) else {
            throw MSLRuntimeError("bundled helper missing: \(record.name)")
        }
        try verifyFileChecksum(toolURL, expected: record.checksum, errorContext: errorContext)
    }

    private func verifyFileChecksum(_ url: URL, expected: String, errorContext: String) throws {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest.caseInsensitiveCompare(expected) == .orderedSame else {
            throw MSLRuntimeError("\(errorContext): \(url.lastPathComponent)")
        }
    }

    private func sanitizeDigestForPath(_ digest: String) -> String {
        digest.replacingOccurrences(of: ":", with: "_")
    }

    private func containerCacheBaseDirectory(registry: String, repository: String, digest: String) -> URL {
        repository
            .split(separator: "/")
            .reduce(
                paths.cacheDownloadsDir
                    .appendingPathComponent("containers", isDirectory: true)
                    .appendingPathComponent(registry, isDirectory: true)
            ) { partial, component in
                partial.appendingPathComponent(String(component), isDirectory: true)
            }
            .appendingPathComponent(digest, isDirectory: true)
    }

    private func copyDirectoryContents(from source: URL, to destination: URL) throws {
        let contents = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for item in contents {
            let target = destination.appendingPathComponent(item.lastPathComponent, isDirectory: true)
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.copyItem(at: item, to: target)
        }
    }

    internal func normalizeContainerRootFSPermissions(rootfsDir: URL) throws {
        var normalizedCount = 0
        let enumerator = fileManager.enumerator(
            at: rootfsDir,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles],
            errorHandler: { url, error in
                self.logger.log("container_rootfs_permission_walk_failed", fields: [
                    "path": url.path,
                    "error": error.localizedDescription
                ])
                return false
            }
        )

        while let item = enumerator?.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true || values.isRegularFile != true {
                continue
            }

            let attributes = try fileManager.attributesOfItem(atPath: item.path)
            guard let modeNumber = attributes[.posixPermissions] as? NSNumber else {
                continue
            }
            let currentMode = modeNumber.uint16Value
            if currentMode & 0o400 != 0 {
                continue
            }
            let normalizedMode = currentMode | 0o400
            do {
                try fileManager.setAttributes([.posixPermissions: NSNumber(value: normalizedMode)], ofItemAtPath: item.path)
            } catch {
                throw MSLRuntimeError("failed to normalize container rootfs permissions: \(item.path)")
            }
            normalizedCount += 1
        }

        logger.log("container_rootfs_permissions_normalized", fields: [
            "rootfs": rootfsDir.path,
            "file_count": String(normalizedCount)
        ])
    }

    private func initialUserConvergencePolicy(for source: DistributionSourceSelection) -> UserConvergencePolicy {
        switch source {
        case .manifest(let entry):
            return entry.userConvergenceTemplate ?? defaultPolicyTemplate(forManifestEntry: entry)
        case .localFile, .containerRemote, .containerRuntime:
            return makeUseraddPolicyTemplate(
                templateID: "generic-useradd-v1",
                adminGroup: "sudo",
                shellFallbacks: ["/bin/bash", "/bin/sh"],
                editable: true
            )
        }
    }

    private func initialCacheSharingPolicy(for source: DistributionSourceSelection) -> CacheSharingConfig {
        switch source {
        case .manifest(let entry):
            if let defaults = entry.cacheSharingDefaults {
                return defaults
            }
            return defaultCacheSharingPolicy(distroFamily: entry.distro)
        case .localFile, .containerRemote, .containerRuntime:
            return defaultCacheSharingPolicy(distroFamily: nil)
        }
    }

    private func defaultCacheSharingPolicy(distroFamily: String?) -> CacheSharingConfig {
        CacheSharingPolicyResolver.defaultConfigForDistroFamily(distroFamily)
    }

    private func backfillUserConvergencePolicy(for metadata: DistributionInstanceMetadata) -> UserConvergencePolicy {
        if let manifestID = metadata.source.manifestId,
           let entry = manifestStore.allEntries().first(where: { $0.id == manifestID }) {
            return entry.userConvergenceTemplate ?? defaultPolicyTemplate(forManifestEntry: entry)
        }

        if let distro = metadata.source.distro?.lowercased() {
            if distro == "alpine" {
                return makeBusyboxPolicyTemplate(
                    templateID: "alpine-busybox-v1",
                    adminGroup: "wheel",
                    shellFallbacks: ["/bin/ash", "/bin/sh"],
                    editable: true
                )
            }
            if distro == "ubuntu" {
                return makeUseraddPolicyTemplate(
                    templateID: "ubuntu-useradd-v1",
                    adminGroup: "sudo",
                    shellFallbacks: ["/bin/bash", "/bin/sh"],
                    editable: true
                )
            }
        }

        if metadata.source.sourceType == "local" || metadata.source.sourceType == "container-remote" {
            return makeUseraddPolicyTemplate(
                templateID: "generic-useradd-v1",
                adminGroup: "sudo",
                shellFallbacks: ["/bin/bash", "/bin/sh"],
                editable: true
            )
        }

        return makeUseraddPolicyTemplate(
            templateID: "default-useradd-v1",
            adminGroup: "sudo",
            shellFallbacks: ["/bin/bash", "/bin/sh"],
            editable: true
        )
    }

    private func initialWorkspacePolicy() -> WorkspacePolicy {
        WorkspacePolicy(
            activationMode: "mslconfig_presence_only",
            startupMountEnabled: true,
            protectedGuestPathPrefixes: WorkspaceActivationResolver.defaultProtectedGuestPathPrefixes
        )
    }

    private func initialNetworkPolicy() -> DistributionNetworkPolicy {
        DistributionNetworkPolicy(
            dns: DistributionNetworkDNSPolicy(
                mode: "host",
                resolverBackend: DNSPolicyResolver.defaultResolverBackend,
                manualNameservers: nil,
                manualSearchDomains: nil
            )
        )
    }

    private func initialRuntimeProfile(
        for source: DistributionSourceSelection,
        instanceName: String
    ) -> DistributionInstanceMetadata.RuntimeInitProfile {
        let resolvedServiceManager = resolveServiceManager(for: source)
        let manifestDefaultMode = resolveManifestDefaultInitMode(for: source)
        let serviceManager = resolvedServiceManager ?? "systemd"
        let canUseServiceManaged: Bool
        switch source {
        case .manifest:
            canUseServiceManaged = resolvedServiceManager != nil
        case .localFile, .containerRemote:
            canUseServiceManaged = false
        case .containerRuntime:
            canUseServiceManaged = true
        }
        let initMode: String
        if isReservedInternalInstanceName(instanceName) {
            initMode = "direct-init"
        } else if let manifestDefaultMode {
            if manifestDefaultMode == "service-managed-init", !canUseServiceManaged {
                initMode = "direct-init"
            } else {
                initMode = manifestDefaultMode
            }
        } else if !canUseServiceManaged {
            initMode = "direct-init"
        } else {
            initMode = "service-managed-init"
        }
        return DistributionInstanceMetadata.RuntimeInitProfile(
            initMode: initMode,
            serviceManager: serviceManager
        )
    }

    private func backfillRuntimeProfile(
        metadata: DistributionInstanceMetadata,
        preferServiceManaged: Bool
    ) -> DistributionInstanceMetadata.RuntimeInitProfile {
        runtimeProfileForSourceRecord(
            metadata.source,
            instanceName: metadata.name,
            preferServiceManaged: preferServiceManaged
        )
    }

    private func runtimeProfileForSourceRecord(
        _ source: DistributionSourceRecord,
        instanceName: String,
        preferServiceManaged: Bool
    ) -> DistributionInstanceMetadata.RuntimeInitProfile {
        if source.sourceType == "container-runtime" {
            return DistributionInstanceMetadata.RuntimeInitProfile(
                initMode: "service-managed-init",
                serviceManager: "openrc"
            )
        }
        let resolvedServiceManager = resolveServiceManager(for: source)
        let manifestDefaultMode = resolveManifestDefaultInitMode(for: source)
        let serviceManager = resolvedServiceManager ?? "systemd"
        let initMode: String
        if isReservedInternalInstanceName(instanceName) {
            initMode = "direct-init"
        } else if let manifestDefaultMode {
            if manifestDefaultMode == "service-managed-init", resolvedServiceManager == nil {
                initMode = "direct-init"
            } else {
                initMode = manifestDefaultMode
            }
        } else if preferServiceManaged, resolvedServiceManager != nil {
            initMode = "service-managed-init"
        } else {
            initMode = "direct-init"
        }
        return DistributionInstanceMetadata.RuntimeInitProfile(
            initMode: initMode,
            serviceManager: serviceManager
        )
    }

    private func resolveServiceManager(for source: DistributionSourceSelection) -> String? {
        switch source {
        case .manifest(let entry):
            if let explicit = normalizeServiceManager(entry.serviceManager) {
                return explicit
            }
            return inferServiceManagerFromDistro(entry.distro)
        case .localFile, .containerRemote:
            return nil
        case .containerRuntime:
            return "openrc"
        }
    }

    private func resolveManifestDefaultInitMode(for source: DistributionSourceSelection) -> String? {
        switch source {
        case .manifest(let entry):
            return normalizeInitMode(entry.defaultInitMode)
        case .localFile, .containerRemote:
            return nil
        case .containerRuntime:
            return "service-managed-init"
        }
    }

    private func resolveManifestDefaultInitMode(for source: DistributionSourceRecord) -> String? {
        guard let manifestID = source.manifestId,
              let entry = manifestStore.allEntries().first(where: { $0.id == manifestID }) else {
            return nil
        }
        return normalizeInitMode(entry.defaultInitMode)
    }

    private func resolveServiceManager(for source: DistributionSourceRecord) -> String? {
        if source.sourceType == "container-runtime" {
            return "openrc"
        }
        if let manifestID = source.manifestId,
           let entry = manifestStore.allEntries().first(where: { $0.id == manifestID }),
           let explicit = normalizeServiceManager(entry.serviceManager) {
            return explicit
        }
        if let distro = source.distro {
            return inferServiceManagerFromDistro(distro)
        }
        return inferServiceManagerFromDistro(inferDistroFamily(from: source.manifestId) ?? "")
    }

    private func normalizeServiceManager(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        switch normalized {
        case "systemd", "openrc":
            return normalized
        default:
            return nil
        }
    }

    private func normalizeInitMode(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        switch normalized {
        case "direct-init", "service-managed-init":
            return normalized
        default:
            return nil
        }
    }

    private func inferServiceManagerFromDistro(_ distro: String) -> String? {
        let normalized = distro.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty {
            return nil
        }
        if normalized.contains("alpine") {
            return "openrc"
        }
        if normalized.contains("ubuntu") {
            return "systemd"
        }
        return nil
    }

    private func resolveCompressionPolicyForInstall() throws -> DistributionCompressionPolicy {
        let store = CompressionCachePolicyCatalogStore(paths: paths, fileManager: fileManager)
        _ = try store.ensureDefaultCatalogIfMissing()

        let cacheToggles = try resolveStorageCacheToggles()
        let basePolicies = defaultCompressionPathPolicies()
        let merged = try store.merge(basePolicies: basePolicies, cacheToggles: cacheToggles)

        return DistributionCompressionPolicy(
            pathPolicies: merged,
            cacheToggles: cacheToggles,
            catalogPath: store.catalogFile.path,
            resolvedAtEpochMs: nowEpochMs()
        )
    }

    private func defaultCompressionPathPolicies() -> [CompressionPathPolicyEntry] {
        [
            CompressionPathPolicyEntry(path: "/usr", mode: "zstd:15"),
            CompressionPathPolicyEntry(path: "/usr/local", mode: "zstd:15"),
            CompressionPathPolicyEntry(path: "/opt", mode: "zstd:15"),
            CompressionPathPolicyEntry(path: "/var/lib", mode: "zstd:15"),
            CompressionPathPolicyEntry(path: "/var/cache/apt", mode: "none"),
            CompressionPathPolicyEntry(path: "/var/log", mode: "zstd:1")
        ]
    }

    private func resolveStorageCacheToggles() throws -> [String: Bool] {
        var toggles: [String: Bool] = [
            "docker": false,
            "go": true,
            "apt": true,
            "apk": true
        ]

        if fileManager.fileExists(atPath: paths.configFile.path) {
            if let data = try? Data(contentsOf: paths.configFile),
               let config = try? JSONDecoder().decode(MSLConfig.self, from: data),
               let overrides = config.storageCacheToggles {
                for (name, isEnabled) in overrides {
                    let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    guard !key.isEmpty else { continue }
                    toggles[key] = isEnabled
                }
            }
        }

        return toggles
    }

    private func defaultPolicyTemplate(forManifestEntry entry: DistributionManifestEntry) -> UserConvergencePolicy {
        switch entry.distro.lowercased() {
        case "alpine":
            return makeBusyboxPolicyTemplate(
                templateID: "alpine-busybox-v1",
                adminGroup: "wheel",
                shellFallbacks: ["/bin/ash", "/bin/sh"]
            )
        default:
            return makeUseraddPolicyTemplate(
                templateID: "ubuntu-useradd-v1",
                adminGroup: "sudo",
                shellFallbacks: ["/bin/bash", "/bin/sh"]
            )
        }
    }

    static func inferDistroFamilyStatic(from manifestID: String?) -> String? {
        guard let manifestID else { return nil }
        let lowered = manifestID.lowercased()
        if lowered.contains("alpine") { return "alpine" }
        if lowered.contains("ubuntu") { return "ubuntu" }
        return nil
    }

    private func inferDistroFamily(from manifestID: String?) -> String? {
        Self.inferDistroFamilyStatic(from: manifestID)
    }

    private func resolveDefaultRuntimeUserName() -> String {
        let envUser = ProcessInfo.processInfo.environment["USER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !envUser.isEmpty {
            return envUser
        }

        let systemUser = NSUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return systemUser.isEmpty ? "msl" : systemUser
    }

    private func resolveImagewriterBuildScriptPath(mslExecutablePath: String) throws -> String {
        let envPath = ProcessInfo.processInfo.environment["MSL_IMAGEWRITER_BUILD_SCRIPT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let envPath, !envPath.isEmpty, fileManager.fileExists(atPath: envPath) {
            return envPath
        }

        let executableURL = URL(fileURLWithPath: mslExecutablePath)
        let currentDirURL = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let candidates: [URL] = [
            executableURL
                .deletingLastPathComponent() // .../.build/debug
                .deletingLastPathComponent() // .../.build
                .deletingLastPathComponent() // repo root
                .appendingPathComponent("scripts/imagewriter-build.sh", isDirectory: false),
            currentDirURL.appendingPathComponent("scripts/imagewriter-build.sh", isDirectory: false)
        ]

        if let found = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) {
            return found.path
        }

        throw MSLRuntimeError(
            "imagewriter build script not found. set MSL_IMAGEWRITER_BUILD_SCRIPT or run from repository root."
        )
    }

    private func runImagewriterBuild(
        scriptPath: String,
        mslExecutablePath: String,
        rootfsTarballPath: String?,
        rootfsDirectoryPath: String?,
        ociLayoutDirectoryPath: String?,
        outputDiskPath: String,
        outputStateDiskPath: String? = nil,
        outputStateTemplateDiskPath: String? = nil,
        sizeMB: Int,
        initBinaryPath: String,
        earlyInitBinaryPath: String? = nil,
        imageFS: String = "btrfs",
        imagewriterPackages: String? = nil,
        imagewriterRootFSPackages: String? = nil,
        extraGuestFilesBundlePath: String? = nil,
        runtimeValidationSummaryPath: String? = nil,
        requestedDefaultExec: DistributionInstanceMetadata.DefaultExec? = nil,
        source: DistributionSourceSelection? = nil
    ) throws {
        if (rootfsTarballPath?.isEmpty ?? true) &&
            (rootfsDirectoryPath?.isEmpty ?? true) &&
            (ociLayoutDirectoryPath?.isEmpty ?? true) {
            throw MSLRuntimeError("imagewriter build requires a rootfs tarball, rootfs directory, or OCI layout")
        }
        var env: [String: String] = [
            "MSL_BIN": mslExecutablePath,
            "IMAGEWRITER_CLEAN_DISTROS": "0",
            "IMAGEWRITER_FORCE_SETUP": "0",
            "IMAGEWRITER_ALLOW_SETUP_WHEN_MISSING": "0",
            "IMAGEWRITER_REQUIRED_FS": "erofs",
            "IMAGE_FS": imageFS,
            "OUTPUT_RAW": outputDiskPath,
            "IMAGE_SIZE_MB": String(sizeMB),
            "IMAGEWRITER_INIT_BINARY": initBinaryPath,
            "IMAGEWRITER_RUN_TIMEOUT": "900",
            "IMAGEWRITER_PACKAGES": imagewriterPackages ?? Self.defaultImagewriterPackages,
            "IMAGEWRITER_ROOTFS_PACKAGES": imagewriterRootFSPackages ?? ""
        ]
        if let earlyInitBinaryPath, !earlyInitBinaryPath.isEmpty {
            env["IMAGEWRITER_EARLY_INIT_BINARY"] = earlyInitBinaryPath
        }
        if let outputStateDiskPath, !outputStateDiskPath.isEmpty {
            env["OUTPUT_STATE_RAW"] = outputStateDiskPath
            env["STATE_IMAGE_SIZE_MB"] = String(sizeMB)
        }
        if let outputStateTemplateDiskPath, !outputStateTemplateDiskPath.isEmpty {
            env["OUTPUT_STATE_TEMPLATE_RAW"] = outputStateTemplateDiskPath
            env["STATE_IMAGE_SIZE_MB"] = String(sizeMB)
        }
        if let rootfsTarballPath, !rootfsTarballPath.isEmpty {
            env["ROOTFS_TARBALL"] = rootfsTarballPath
        }
        if let rootfsDirectoryPath, !rootfsDirectoryPath.isEmpty {
            env["ROOTFS_DIR"] = rootfsDirectoryPath
        }
        if let ociLayoutDirectoryPath, !ociLayoutDirectoryPath.isEmpty {
            env["OCI_LAYOUT_DIR"] = ociLayoutDirectoryPath
        }
        if let extraGuestFilesBundlePath, !extraGuestFilesBundlePath.isEmpty {
            env["EXTRA_GUEST_FILES_BUNDLE"] = extraGuestFilesBundlePath
        }
        if let runtimeValidationSummaryPath, !runtimeValidationSummaryPath.isEmpty {
            env["IMAGEWRITER_RUNTIME_SUMMARY_PATH"] = runtimeValidationSummaryPath
        }
        if let requestedDefaultExec {
            env["IMAGEWRITER_DEFAULT_EXEC_ARGV_B64"] = Data(requestedDefaultExec.argv.joined(separator: "\n").utf8).base64EncodedString()
            env["IMAGEWRITER_DEFAULT_EXEC_ENV_B64"] = Data(requestedDefaultExec.env.joined(separator: "\n").utf8).base64EncodedString()
            if let workingDir = requestedDefaultExec.workingDir, !workingDir.isEmpty {
                env["IMAGEWRITER_DEFAULT_EXEC_WORKDIR"] = workingDir
            }
            if let user = requestedDefaultExec.user, !user.isEmpty {
                env["IMAGEWRITER_DEFAULT_EXEC_USER"] = user
            }
        }
        if let mslHome = ProcessInfo.processInfo.environment["MSL_HOME"], !mslHome.isEmpty {
            env["MSL_HOME"] = mslHome
        }
        if let shareRoot = ProcessInfo.processInfo.environment["MSL_HOST_SHARE_ROOT"], !shareRoot.isEmpty {
            env["MSL_HOST_SHARE_ROOT"] = shareRoot
        }
        if let configuredInstance = ProcessInfo.processInfo.environment["MSL_IMAGEWRITER_INSTANCE"], !configuredInstance.isEmpty {
            env["IMAGEWRITER_INSTANCE"] = configuredInstance
        }

        let result = try process.run("/bin/sh", [scriptPath], captureOutput: true, environment: env)
        guard result.exitCode == 0 else {
            var scriptDiagnostics = imagewriterFailureDiagnostics(from: result)
            if scriptDiagnostics.stdoutLog == nil && scriptDiagnostics.stderrLog == nil {
                scriptDiagnostics = persistImagewriterFailureLogs(result: result, existing: scriptDiagnostics)
            }
            let stageHint: String
            if let guestStage = scriptDiagnostics.stage {
                stageHint = "stage=\(guestStage)"
            } else {
                switch result.exitCode {
                case 21:
                    stageHint = "stage=stage1_ext4"
                case 22:
                    stageHint = "stage=btrfs_build"
                case 23:
                    stageHint = "stage=finalize"
                case 24:
                    stageHint = "stage=imagewriter_verify"
                case 25:
                    stageHint = "stage=imagewriter_missing"
                case 26:
                    stageHint = "stage=container_unpack"
                case 1 where result.stderr.contains("init channel did not connect within"):
                    stageHint = "stage=worker_startup"
                case 1 where result.stderr.contains("worker did not register in time"):
                    stageHint = "stage=worker_startup"
                default:
                    stageHint = "stage=unknown"
                }
            }
            let detailHint: String
            if stageHint == "stage=worker_startup",
               let workerSerialLog = imagewriterWorkerSerialLogPath() {
                detailHint = " see guest serial log: \(workerSerialLog)"
            } else if let stderrLog = scriptDiagnostics.stderrLog {
                detailHint = " see guest log: \(stderrLog)"
            } else if result.exitCode == 22, case .containerRemote? = source {
                detailHint = " container rootfs permissions may be incompatible."
            } else if result.exitCode == 26, case .containerRemote? = source {
                detailHint = " guest container unpack or default-command validation failed."
            } else {
                detailHint = ""
            }
            throw MSLRuntimeError(
                "imagewriter build failed (\(result.exitCode), \(stageHint)).\(detailHint) see imagewriter logs/output above."
            )
        }
    }

    private func imagewriterFailureDiagnostics(from result: ProcessResult) -> (stage: String?, stdoutLog: String?, stderrLog: String?) {
        let lines = result.stderr
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        guard let marker = lines.last(where: { $0.contains("imagewriter_guest_failure_detected") }) else {
            return (nil, nil, nil)
        }
        let stage = value(after: "stage=", in: marker)
        let stdoutLog = value(after: "stdout_log=", in: marker)
        let stderrLog = value(after: "stderr_log=", in: marker)
        return (stage, stdoutLog, stderrLog)
    }

    private func persistImagewriterFailureLogs(
        result: ProcessResult,
        existing: (stage: String?, stdoutLog: String?, stderrLog: String?)
    ) -> (stage: String?, stdoutLog: String?, stderrLog: String?) {
        let instanceName = resolveImagewriterInstanceName()
        let logsDirectory = paths.instanceLogsDirectory(named: instanceName)
            .appendingPathComponent("imagewriter-build", isDirectory: true)
        do {
            try ensureDir(logsDirectory)
            let stamp = String(nowEpochMs())
            let stdoutURL = logsDirectory.appendingPathComponent("imagewriter-\(stamp).stdout.log", isDirectory: false)
            let stderrURL = logsDirectory.appendingPathComponent("imagewriter-\(stamp).stderr.log", isDirectory: false)
            try result.stdout.write(to: stdoutURL, atomically: true, encoding: .utf8)
            try result.stderr.write(to: stderrURL, atomically: true, encoding: .utf8)
            return (
                stage: existing.stage,
                stdoutLog: stdoutURL.path,
                stderrLog: stderrURL.path
            )
        } catch {
            logger.log("imagewriter_failure_log_persist_failed", fields: [
                "instance": instanceName,
                "error": error.localizedDescription
            ])
            return existing
        }
    }

    private func value(after prefix: String, in line: String) -> String? {
        guard let range = line.range(of: prefix) else {
            return nil
        }
        let suffix = line[range.upperBound...]
        let token = suffix.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init)
        return token?.isEmpty == false ? token : nil
    }

    private func resolveImagewriterInstanceName() -> String {
        let envValue = ProcessInfo.processInfo.environment["MSL_IMAGEWRITER_INSTANCE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let envValue, !envValue.isEmpty {
            return envValue
        }
        return "_imagewriter"
    }

    func resolveContainerRuntimeInstanceName() -> String {
        Self.containerRuntimeInstanceName
    }

    private func allowInternalContainerRuntimeInstallSurface() -> Bool {
        let raw = environment["MSL_ALLOW_INTERNAL_CONTAINER_RUNTIME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return raw == "1" || raw == "true" || raw == "yes"
    }

    private func imagewriterWorkerSerialLogPath() -> String? {
        let path = paths
            .workerRuntimeDirectory(named: resolveImagewriterInstanceName())
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("serial-console.log", isDirectory: false)
        return fileManager.fileExists(atPath: path.path) ? path.path : nil
    }

    static func imagewriterStopArguments(instanceName: String) -> [String] {
        ["--instance", instanceName, "stop"]
    }

    private func stopImagewriterInstance(mslExecutablePath: String, instanceName: String) {
        do {
            let result = try process.run(
                mslExecutablePath,
                Self.imagewriterStopArguments(instanceName: instanceName),
                captureOutput: true,
                environment: [:]
            )
            if result.exitCode == 0 {
                logger.log("imagewriter_runtime_stop_succeeded", fields: [
                    "instance": instanceName
                ])
            } else {
                let detail = (result.stderr + "\n" + result.stdout)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                logger.log("imagewriter_runtime_stop_failed", fields: [
                    "instance": instanceName,
                    "exitCode": String(result.exitCode),
                    "detail": detail
                ])
            }
        } catch {
            logger.log("imagewriter_runtime_stop_failed", fields: [
                "instance": instanceName,
                "error": String(describing: error)
            ])
        }
    }

    private func resolveImagewriterBootloaderBinaryPath() throws -> String {
        let envPath = ProcessInfo.processInfo.environment["MSL_INIT_BOOTLOADER_BINARY_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sourcePath: String
        if let envPath, !envPath.isEmpty {
            sourcePath = envPath
        } else {
            sourcePath = paths.mslHostInitBootloaderBinaryFile.path
        }

        guard fileManager.fileExists(atPath: sourcePath) else {
            throw MSLRuntimeError(
                "msl-init-bootloader binary not found at \(sourcePath). run `./scripts/build-msl-init.sh` or set MSL_INIT_BOOTLOADER_BINARY_PATH."
            )
        }
        return sourcePath
    }

    private func resolveImagewriterEarlyInitBinaryPath() throws -> String {
        let envPath = ProcessInfo.processInfo.environment["MSL_EARLY_INIT_BINARY_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sourcePath: String
        if let envPath, !envPath.isEmpty {
            sourcePath = envPath
        } else {
            sourcePath = paths.mslHostEarlyInitBinaryFile.path
        }

        guard fileManager.fileExists(atPath: sourcePath) else {
            throw MSLRuntimeError(
                "msl-early-init binary not found at \(sourcePath). run `./scripts/build-msl-init.sh` or set MSL_EARLY_INIT_BINARY_PATH."
            )
        }
        return sourcePath
    }

    private func installEarlyInitIntoRootfs(rootfsDir: URL, earlyInitBinaryPath: String?) throws {
        guard let earlyInitBinaryPath, !earlyInitBinaryPath.isEmpty else {
            throw MSLRuntimeError("container-runtime COW build is missing msl-early-init binary path")
        }
        let earlyInitURL = URL(fileURLWithPath: earlyInitBinaryPath, isDirectory: false)
        let initURL = rootfsDir.appendingPathComponent("init", isDirectory: false)
        if fileManager.fileExists(atPath: initURL.path) {
            try fileManager.removeItem(at: initURL)
        }
        try fileManager.copyItem(at: earlyInitURL, to: initURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: initURL.path)
        for relativePath in ["run/msl/base", "run/msl/state", "run/msl/tmp", "sysroot"] {
            try ensureDir(rootfsDir.appendingPathComponent(relativePath, isDirectory: true))
        }
    }

    private func rebuildInstanceMetadata(at metadataURL: URL) throws -> DistributionInstanceMetadata {
        let instanceName = metadataURL.deletingLastPathComponent().lastPathComponent
        let diskURL = paths.distroDiskFile(named: instanceName)
        guard fileManager.fileExists(atPath: diskURL.path) else {
            throw MSLRuntimeError("cannot rebuild metadata for '\(instanceName)': disk image is missing")
        }

        let sourceURL = paths.distroSourceFile(named: instanceName)
        let sourceRecord: DistributionSourceRecord
        if fileManager.fileExists(atPath: sourceURL.path) {
            sourceRecord = try readJSON(DistributionSourceRecord.self, from: sourceURL)
        } else {
            sourceRecord = DistributionSourceRecord(
                sourceType: "unknown",
                distro: nil,
                version: nil,
                arch: nil,
                manifestId: nil,
                localPath: nil,
                tarballFileName: "",
                sha256: "",
                verifiedAtEpochMs: nowEpochMs()
            )
        }

        var createdAtEpochMs = nowEpochMs()
        if let attrs = try? fileManager.attributesOfItem(atPath: diskURL.path),
           let created = attrs[.creationDate] as? Date {
            createdAtEpochMs = Int64(created.timeIntervalSince1970 * 1000)
        }

        let recoveredPolicy: UserConvergencePolicy
        if sourceRecord.distro?.lowercased() == "alpine" {
            recoveredPolicy = makeBusyboxPolicyTemplate(
                templateID: "alpine-busybox-v1",
                adminGroup: "wheel",
                shellFallbacks: ["/bin/ash", "/bin/sh"],
                editable: true
            )
        } else {
            recoveredPolicy = makeUseraddPolicyTemplate(
                templateID: "default-useradd-v1",
                adminGroup: "sudo",
                shellFallbacks: ["/bin/bash", "/bin/sh"],
                editable: true
            )
        }

        let metadata = DistributionInstanceMetadata(
            name: instanceName,
            distroFamily: sourceRecord.distro ?? inferDistroFamily(from: sourceRecord.manifestId),
            createdAtEpochMs: createdAtEpochMs,
            bootstrap: DistributionInstanceMetadata.PrivilegeBootstrap(
                firstBootPending: true,
                privilegeBootstrapVersion: 1,
                lastResult: "recovered",
                lastBootstrapAtEpochMs: nil
            ),
            user: DistributionInstanceMetadata.UserSnapshot(
                name: resolveDefaultRuntimeUserName(),
                uid: Int(getuid()),
                gid: Int(getgid()),
                groups: [recoveredPolicy.adminGroup]
            ),
            source: sourceRecord,
            diskPath: diskURL.path,
            kernelProfileRef: nil,
            runtimeProfile: runtimeProfileForSourceRecord(
                sourceRecord,
                instanceName: instanceName,
                preferServiceManaged: false
            ),
            userConvergencePolicy: recoveredPolicy,
            workspacePolicy: initialWorkspacePolicy(),
            compressionPolicy: nil,
            networkPolicy: initialNetworkPolicy(),
            cacheSharing: defaultCacheSharingPolicy(
                distroFamily: sourceRecord.distro ?? inferDistroFamily(from: sourceRecord.manifestId)
            ),
            tmpStorage: nil,
            startupMode: resolveStartupMode(source: sourceRecord, shellAvailable: true),
            workloadKind: resolveWorkloadKind(source: sourceRecord)
        )
        try writeJSON(metadata, to: metadataURL)
        return metadata
    }

    private func makeUseraddPolicyTemplate(
        templateID: String,
        adminGroup: String,
        shellFallbacks: [String],
        editable: Bool = false
    ) -> UserConvergencePolicy {
        UserConvergencePolicy(
            templateId: templateID,
            commandFamily: "useradd",
            adminGroup: adminGroup,
            sudoPolicy: SudoPolicyTemplate(
                enabled: true,
                requireSudoBinary: false,
                dropInPath: "/etc/sudoers.d/msl-user",
                passwordless: true
            ),
            suPolicy: SuPolicyTemplate(
                enabled: false,
                passwordless: false
            ),
            shellFallbacks: shellFallbacks,
            welcomePolicy: WelcomePolicyTemplate(
                enabled: true,
                frequency: "daily",
                respectHushlogin: true
            ),
            editable: editable
        )
    }

    private func makeBusyboxPolicyTemplate(
        templateID: String,
        adminGroup: String,
        shellFallbacks: [String],
        editable: Bool = false
    ) -> UserConvergencePolicy {
        UserConvergencePolicy(
            templateId: templateID,
            commandFamily: "busybox_adduser",
            adminGroup: adminGroup,
            sudoPolicy: SudoPolicyTemplate(
                enabled: true,
                requireSudoBinary: false,
                dropInPath: "/etc/sudoers.d/msl-user",
                passwordless: true
            ),
            suPolicy: SuPolicyTemplate(
                enabled: true,
                passwordless: true
            ),
            shellFallbacks: shellFallbacks,
            welcomePolicy: WelcomePolicyTemplate(
                enabled: true,
                frequency: "daily",
                respectHushlogin: true
            ),
            editable: editable
        )
    }

    private func validateUserConvergencePolicy(
        _ policy: UserConvergencePolicy,
        metadataURL: URL
    ) throws -> UserConvergencePolicy {
        let commandFamily = policy.commandFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        if commandFamily != "useradd" && commandFamily != "busybox_adduser" {
            throw MSLRuntimeError(
                "invalid userConvergencePolicy.commandFamily '\(policy.commandFamily)' in \(metadataURL.path). " +
                "supported values: useradd, busybox_adduser"
            )
        }

        let adminGroup = policy.adminGroup.trimmingCharacters(in: .whitespacesAndNewlines)
        if adminGroup.isEmpty {
            throw MSLRuntimeError(
                "invalid userConvergencePolicy.adminGroup in \(metadataURL.path): empty value is not allowed"
            )
        }

        if !policy.sudoPolicy.dropInPath.hasPrefix("/") {
            throw MSLRuntimeError(
                "invalid userConvergencePolicy.sudoPolicy.dropInPath in \(metadataURL.path): " +
                "absolute path required"
            )
        }

        if policy.shellFallbacks.isEmpty {
            throw MSLRuntimeError(
                "invalid userConvergencePolicy.shellFallbacks in \(metadataURL.path): at least one shell path required"
            )
        }
        for shell in policy.shellFallbacks {
            if !shell.hasPrefix("/") {
                throw MSLRuntimeError(
                    "invalid userConvergencePolicy.shellFallbacks entry '\(shell)' in \(metadataURL.path): " +
                    "absolute path required"
                )
            }
        }

        let allowedWelcomeFrequency = Set(["always", "daily", "never"])
        if !allowedWelcomeFrequency.contains(policy.welcomePolicy.frequency) {
            throw MSLRuntimeError(
                "invalid userConvergencePolicy.welcomePolicy.frequency '\(policy.welcomePolicy.frequency)' in " +
                "\(metadataURL.path). supported values: always, daily, never"
            )
        }

        return UserConvergencePolicy(
            templateId: policy.templateId.trimmingCharacters(in: .whitespacesAndNewlines),
            commandFamily: commandFamily,
            adminGroup: adminGroup,
            sudoPolicy: policy.sudoPolicy,
            suPolicy: policy.suPolicy,
            shellFallbacks: policy.shellFallbacks,
            welcomePolicy: policy.welcomePolicy,
            editable: policy.editable
        )
    }

    internal func fetchManifestEntry(_ entry: DistributionManifestEntry, force: Bool) throws -> DistributionVerifiedRecord {
        try migrateLegacyRootfsCacheIfNeeded()
        let cacheDir = paths.cacheDownloadsDir
            .appendingPathComponent(entry.distro, isDirectory: true)
            .appendingPathComponent(entry.version, isDirectory: true)
            .appendingPathComponent(entry.arch, isDirectory: true)
        try ensureDir(cacheDir)

        let tarballFileName = URL(string: entry.tarballURL)?.lastPathComponent ?? "\(entry.id).tar"
        let tarballPath = cacheDir.appendingPathComponent(tarballFileName, isDirectory: false)
        let verifiedPath = cacheDir.appendingPathComponent("verified.json", isDirectory: false)
        let signaturePath = cacheDir.appendingPathComponent("\(tarballFileName).asc", isDirectory: false)
        let checksumPath = cacheDir.appendingPathComponent("\(tarballFileName).sha256", isDirectory: false)

        if !force {
            let cacheStatus = try manifestCacheRecordIfUsable(
                entry: entry,
                tarballPath: tarballPath,
                verifiedPath: verifiedPath
            )
            switch cacheStatus {
            case .hit(let existing):
                logger.log("cache_hit", fields: ["id": entry.id, "path": tarballPath.path])
                emitStatus("install: using cached archive \(tarballFileName)")
                return existing
            case .invalidChecksum(let expected, let actual):
                logger.log("cache_invalid", fields: [
                    "id": entry.id,
                    "path": tarballPath.path,
                    "expected_sha256": expected,
                    "actual_sha256": actual
                ])
                emitStatus("install: cached archive checksum mismatch; refetching \(tarballFileName)")
            case .miss:
                break
            }
        }

        logger.log("cache_fetch_started", fields: ["id": entry.id, "url": entry.tarballURL])

        let tmpFile = cacheDir.appendingPathComponent("\(tarballFileName).part", isDirectory: false)
        if fileManager.fileExists(atPath: tmpFile.path) { try fileManager.removeItem(at: tmpFile) }
        try download(URL(string: entry.tarballURL)!, to: tmpFile)
        if fileManager.fileExists(atPath: tarballPath.path) {
            try fileManager.removeItem(at: tarballPath)
        }
        try fileManager.moveItem(at: tmpFile, to: tarballPath)

        var checksumExpected: String?
        if let checksumURL = entry.checksumURL, !checksumURL.isEmpty {
            try download(URL(string: checksumURL)!, to: checksumPath)
            checksumExpected = try parseSHA256FromChecksumFile(checksumPath, fileName: tarballFileName)
        }

        if let signatureURL = entry.signatureURL, !signatureURL.isEmpty {
            try download(URL(string: signatureURL)!, to: signaturePath)
            guard let keyFingerprint = entry.keyFingerprint, !keyFingerprint.isEmpty else {
                throw MSLRuntimeError("manifest entry '\(entry.id)' missing keyFingerprint for signature verification")
            }
            let target = (entry.signatureTarget ?? (checksumExpected == nil ? "artifact" : "checksum")).lowercased()
            let verifyTarget = target == "checksum" ? checksumPath : tarballPath
            try verifyPGP(
                artifactURL: verifyTarget,
                signatureURL: signaturePath,
                expectedFingerprint: keyFingerprint
            )
        } else {
            throw MSLRuntimeError("manifest entry '\(entry.id)' missing signatureURL")
        }

        let sha = try computeSHA256(fileAt: tarballPath)
        guard sha.caseInsensitiveCompare(entry.sha256) == .orderedSame else {
            throw MSLRuntimeError("sha256 mismatch for \(entry.id): expected \(entry.sha256), got \(sha)")
        }
        if let checksumExpected, sha.caseInsensitiveCompare(checksumExpected) != .orderedSame {
            throw MSLRuntimeError(
                "checksum file mismatch for \(entry.id): expected \(checksumExpected), got \(sha)"
            )
        }

        let verified = DistributionVerifiedRecord(
            tarballPath: tarballPath.path,
            sha256: sha,
            signatureFingerprint: entry.keyFingerprint,
            verifiedAtEpochMs: nowEpochMs(),
            manifestId: entry.id
        )
        try writeJSON(verified, to: verifiedPath)

        logger.log("cache_fetch_completed", fields: ["id": entry.id, "path": tarballPath.path])
        emitStatus("install: fetched archive \(tarballFileName)")
        return verified
    }

    internal enum ManifestCacheStatus {
        case hit(DistributionVerifiedRecord)
        case invalidChecksum(expected: String, actual: String)
        case miss
    }

    internal func manifestCacheRecordIfUsable(
        entry: DistributionManifestEntry,
        tarballPath: URL,
        verifiedPath: URL
    ) throws -> ManifestCacheStatus {
        guard fileManager.fileExists(atPath: tarballPath.path),
              fileManager.fileExists(atPath: verifiedPath.path) else {
            return .miss
        }
        let existing = try readJSON(DistributionVerifiedRecord.self, from: verifiedPath)
        guard existing.sha256.caseInsensitiveCompare(entry.sha256) == .orderedSame,
              existing.manifestId == entry.id else {
            return .miss
        }
        let actualSHA = try computeSHA256(fileAt: tarballPath)
        guard actualSHA.caseInsensitiveCompare(existing.sha256) == .orderedSame else {
            return .invalidChecksum(expected: existing.sha256, actual: actualSHA)
        }
        return .hit(existing)
    }

    internal func cacheLocalFile(_ fileURL: URL, force: Bool) throws -> DistributionVerifiedRecord {
        try migrateLegacyRootfsCacheIfNeeded()
        let sha = try computeSHA256(fileAt: fileURL)
        let short = String(sha.prefix(12))
        let cacheDir = paths.cacheDownloadsDir
            .appendingPathComponent("local", isDirectory: true)
            .appendingPathComponent(short, isDirectory: true)
        try ensureDir(cacheDir)

        let destFile = cacheDir.appendingPathComponent(fileURL.lastPathComponent, isDirectory: false)
        if !fileManager.fileExists(atPath: destFile.path) || force {
            if fileManager.fileExists(atPath: destFile.path) {
                try fileManager.removeItem(at: destFile)
            }
            try fileManager.copyItem(at: fileURL, to: destFile)
        }

        let verified = DistributionVerifiedRecord(
            tarballPath: destFile.path,
            sha256: sha,
            signatureFingerprint: nil,
            verifiedAtEpochMs: nowEpochMs(),
            manifestId: nil
        )
        try writeJSON(verified, to: cacheDir.appendingPathComponent("verified.json", isDirectory: false))
        logger.log("cache_local_file", fields: ["path": fileURL.path, "sha256": sha])
        emitStatus("install: cached local archive \(fileURL.lastPathComponent)")
        return verified
    }

    internal func verifyPGP(
        artifactURL: URL,
        signatureURL: URL,
        expectedFingerprint: String
    ) throws {
        guard let gpg = process.findExecutable(["gpg", "gpgv"]) else {
            throw MSLRuntimeError("PGP verification requires gpg or gpgv installed on host")
        }
        let normalized = normalizeFingerprint(expectedFingerprint)
        guard let armoredKey = TrustedOpenPGPKeys.armoredByFingerprint[normalized] else {
            throw MSLRuntimeError(
                "trusted key fingerprint not embedded: \(normalized). run `make update-distribution-list` and rebuild."
            )
        }

        let tmpDir = fileManager.temporaryDirectory.appendingPathComponent("msl-gpg-\(UUID().uuidString)", isDirectory: true)
        try ensureDir(tmpDir)
        defer { try? fileManager.removeItem(at: tmpDir) }

        let keyFile = tmpDir.appendingPathComponent("trusted.asc", isDirectory: false)
        let keyring = tmpDir.appendingPathComponent("trusted.gpg", isDirectory: false)
        try Data(armoredKey.utf8).write(to: keyFile, options: .atomic)

        let importRes = try process.run(gpg, [
            "--batch",
            "--no-default-keyring",
            "--keyring", keyring.path,
            "--import", keyFile.path
        ], captureOutput: true)
        guard importRes.exitCode == 0 else {
            throw MSLRuntimeError("failed to import trusted key for signature verification")
        }

        let verifyRes = try process.run(gpg, [
            "--batch",
            "--status-fd", "1",
            "--no-default-keyring",
            "--keyring", keyring.path,
            "--verify", signatureURL.path, artifactURL.path
        ], captureOutput: true)
        guard verifyRes.exitCode == 0 else {
            throw MSLRuntimeError("PGP verification failed for \(artifactURL.lastPathComponent)")
        }

        let statusText = verifyRes.stdout + "\n" + verifyRes.stderr
        guard let valid = extractValidSignatureFingerprint(from: statusText) else {
            throw MSLRuntimeError("PGP verification output did not contain VALIDSIG fingerprint")
        }
        if normalizeFingerprint(valid) != normalized {
            throw MSLRuntimeError("PGP signer fingerprint mismatch: expected \(normalized), got \(valid)")
        }
    }

    internal func parseSHA256FromChecksumFile(_ checksumFile: URL, fileName: String) throws -> String {
        let content = try String(contentsOf: checksumFile, encoding: .utf8)
        for line in content.split(separator: "\n") {
            let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty { continue }
            let parts = raw.split(whereSeparator: \.isWhitespace)
            if parts.count >= 2 {
                let sha = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                let tail = String(parts.last ?? "")
                    .replacingOccurrences(of: "*", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if tail == fileName || tail.hasSuffix("/\(fileName)") {
                    return sha
                }
            }
        }
        throw MSLRuntimeError("could not find \(fileName) in checksum file \(checksumFile.lastPathComponent)")
    }

    internal func extractValidSignatureFingerprint(from text: String) -> String? {
        for line in text.split(separator: "\n") {
            let raw = String(line)
            if raw.contains("VALIDSIG ") {
                let comps = raw.components(separatedBy: "VALIDSIG ")
                guard let tail = comps.last else { continue }
                let fp = tail.split(separator: " ").first.map(String.init) ?? ""
                if !fp.isEmpty { return fp }
            }
        }
        return nil
    }

    internal func buildExt4Disk(from rootfsDir: URL, sourceArchive: URL, outputDisk: URL, diskSizeGB: Int) throws {
        let sizeGB = max(1, diskSizeGB)
        if let mkfsHelper = resolveExt4MkfsHelperExecutable(),
           let populateHelper = resolveExt4HelperExecutable() {
            if fileManager.fileExists(atPath: outputDisk.path) {
                try fileManager.removeItem(at: outputDisk)
            }
            let mkfsResult = try process.run(mkfsHelper, [
                "--output", outputDisk.path,
                "--size-gb", String(sizeGB)
            ], captureOutput: true)
            guard mkfsResult.exitCode == 0 else {
                throw MSLRuntimeError(
                    "ext4 mkfs helper failed (\(mkfsResult.exitCode)): " +
                    (mkfsResult.stderr.isEmpty ? mkfsResult.stdout : mkfsResult.stderr)
                )
            }

            let populateArgs = [
                "--rootfs", rootfsDir.path,
                "--output", outputDisk.path,
                "--metadata-from-tar", sourceArchive.path
            ]
            let populateResult = try process.run(populateHelper, populateArgs, captureOutput: true)
            guard populateResult.exitCode == 0 else {
                throw MSLRuntimeError(
                    "ext4 populate helper failed (\(populateResult.exitCode)): " +
                    (populateResult.stderr.isEmpty ? populateResult.stdout : populateResult.stderr)
                )
            }
            logger.log("image_build_ext4_with_helper", fields: [
                "mkfs_helper": mkfsHelper,
                "populate_helper": populateHelper,
                "output": outputDisk.path
            ])
            try compactSparseImageIfSupported(outputDisk)
            return
        }

        guard let mke2fs = process.findExecutable(["mke2fs", "mkfs.ext4"]) else {
            throw MSLRuntimeError(
                "ext4 helper not found and mke2fs/mkfs.ext4 is unavailable. build helper via `make build-ext4-helper` or install e2fsprogs."
            )
        }
        guard let e2fsdroid = process.findExecutable(["e2fsdroid"]) else {
            throw MSLRuntimeError(
                "ext4 helper not found and e2fsdroid is unavailable. build helper via `make build-ext4-helper` or install android/e2fs tools."
            )
        }
        guard let truncate = process.findExecutable(["truncate"]) else {
            throw MSLRuntimeError("ext4 helper not found and truncate is unavailable on host")
        }
        let sizeBytes = UInt64(sizeGB) * 1024 * 1024 * 1024
        if fileManager.fileExists(atPath: outputDisk.path) {
            try fileManager.removeItem(at: outputDisk)
        }

        let trunc = try process.run(truncate, ["-s", String(sizeBytes), outputDisk.path], captureOutput: true)
        guard trunc.exitCode == 0 else {
            throw MSLRuntimeError("failed to allocate disk image at \(outputDisk.path)")
        }

        let mkfs = try process.run(mke2fs, ["-t", "ext4", "-F", outputDisk.path], captureOutput: true)
        guard mkfs.exitCode == 0 else {
            throw MSLRuntimeError("failed to format ext4 image at \(outputDisk.path)")
        }

        let populate = try process.run(e2fsdroid, ["-f", rootfsDir.path, outputDisk.path], captureOutput: true)
        guard populate.exitCode == 0 else {
            throw MSLRuntimeError("failed to populate ext4 image from rootfs at \(rootfsDir.path)")
        }
        try compactSparseImageIfSupported(outputDisk)
    }

    internal func compactSparseImageIfSupported(_ imageURL: URL) throws {
        guard let fallocate = process.findExecutable(["fallocate"]) else {
            return
        }
        _ = try process.run(fallocate, ["-d", imageURL.path], captureOutput: true)
    }

    internal func stageInitBinary(
        intoRootfs rootfsDir: URL,
        runtimeProfile: DistributionInstanceMetadata.RuntimeInitProfile? = nil
    ) throws {
        let envPath = ProcessInfo.processInfo.environment["MSL_INIT_BOOTLOADER_BINARY_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sourcePath: String
        if let envPath, !envPath.isEmpty {
            sourcePath = envPath
        } else {
            sourcePath = paths.mslHostInitBootloaderBinaryFile.path
        }

        guard fileManager.fileExists(atPath: sourcePath) else {
            throw MSLRuntimeError(
                "msl-init-bootloader binary not found at \(sourcePath). run `./scripts/build-msl-init.sh` or set MSL_INIT_BOOTLOADER_BINARY_PATH."
            )
        }

        let sourceURL = URL(fileURLWithPath: sourcePath)
        let destinations = [
            rootfsDir.appendingPathComponent("sbin/msl-init-bootloader", isDirectory: false),
            rootfsDir.appendingPathComponent("usr/local/bin/msl-init-bootloader", isDirectory: false)
        ]
        for dst in destinations {
            try fileManager.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: dst.path) {
                try fileManager.removeItem(at: dst)
            }
            try fileManager.copyItem(at: sourceURL, to: dst)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
        }

        try installWaylandGuestArtifacts(intoRootfs: rootfsDir)
        try normalizeRootFstabForVirtualDisk(rootfsDir: rootfsDir)

        guard let runtimeProfile,
              runtimeProfile.initMode == "service-managed-init" else {
            return
        }
        try installGuestRuntimeServiceContracts(
            rootfsDir: rootfsDir,
            serviceManager: runtimeProfile.serviceManager
        )
    }

    internal func installWaylandGuestArtifacts(intoRootfs rootfsDir: URL) throws {
        let profileDestination = rootfsDir.appendingPathComponent(String(mslGuestWaylandProfileScriptPath.dropFirst()), isDirectory: false)
        try fileManager.createDirectory(at: profileDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(mslWaylandProfileScript().utf8).write(to: profileDestination, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: profileDestination.path)
    }

    private func configureContainerRuntimeRootFS(rootfsDir: URL) throws {
        try ensureDir(rootfsDir.appendingPathComponent("etc/containerd", isDirectory: true))
        try ensureDir(rootfsDir.appendingPathComponent("etc/buildkit", isDirectory: true))
        try ensureDir(rootfsDir.appendingPathComponent("etc/nerdctl", isDirectory: true))
        try ensureDir(rootfsDir.appendingPathComponent("etc/init.d", isDirectory: true))
        try ensureDir(rootfsDir.appendingPathComponent("etc/runlevels/default", isDirectory: true))
        try ensureDir(rootfsDir.appendingPathComponent("usr/local/bin", isDirectory: true))

        if let bundledBuildctl = try? resolveBundledContainerToolArtifact(named: "buildctl", platform: "linux-arm64") {
            let installedBuildctl = rootfsDir.appendingPathComponent("usr/local/bin/buildctl-real", isDirectory: false)
            if fileManager.fileExists(atPath: installedBuildctl.path) {
                try fileManager.removeItem(at: installedBuildctl)
            }
            try fileManager.copyItem(at: bundledBuildctl, to: installedBuildctl)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedBuildctl.path)
        }
        if let bundledYouki = try? resolveBundledContainerToolArtifact(named: "youki", platform: "linux-arm64") {
            let installedYouki = rootfsDir.appendingPathComponent("usr/local/bin/youki", isDirectory: false)
            if fileManager.fileExists(atPath: installedYouki.path) {
                try fileManager.removeItem(at: installedYouki)
            }
            try fileManager.copyItem(at: bundledYouki, to: installedYouki)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedYouki.path)
        }

        try writeText(
            """
            version = 2
            root = "/var/lib/containerd"
            state = "/run/containerd"

            [grpc]
              address = "/run/containerd/containerd.sock"

            [plugins."io.containerd.grpc.v1.cri".containerd]
              snapshotter = "native"
              default_runtime_name = "youki"

            [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.youki]
              runtime_type = "io.containerd.runc.v2"
              privileged_without_host_devices = false
              [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.youki.options]
                BinaryName = "/usr/local/bin/msl-runtime-youki"
                SystemdCgroup = false

            [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
              runtime_type = "io.containerd.runc.v2"
              privileged_without_host_devices = false
              [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
                BinaryName = "/usr/local/bin/msl-runtime-runc"
                SystemdCgroup = false
            """,
            to: rootfsDir.appendingPathComponent("etc/containerd/config.toml", isDirectory: false)
        )

        try writeText(
            """
            root = "/var/lib/buildkit"

            [dns]
              nameservers = ["8.8.8.8", "8.8.4.4", "2001:4860:4860::8888", "2001:4860:4860::8844"]

            [worker.oci]
              enabled = true
              snapshotter = "native"
            """,
            to: rootfsDir.appendingPathComponent("etc/buildkit/buildkitd.toml", isDirectory: false)
        )

        try writeText(
            """
            address = "unix:///run/containerd/containerd.sock"
            snapshotter = "native"
            cgroup_manager = "cgroupfs"
            """,
            to: rootfsDir.appendingPathComponent("etc/nerdctl/nerdctl.toml", isDirectory: false)
        )

        try writeExecutableScript(
            """
            #!/bin/sh
            exec /usr/bin/env CONTAINERD_ADDRESS=/run/containerd/containerd.sock CONTAINERD_SNAPSHOTTER=native BUILDKIT_HOST=unix:///run/buildkit/buildkitd.sock /usr/bin/nerdctl "$@"
            """,
            to: rootfsDir.appendingPathComponent("usr/local/bin/nerdctl", isDirectory: false)
        )
        try writeRuntimeBinaryWrapper(
            name: "msl-runtime-containerd",
            candidates: ["/usr/bin/containerd", "/usr/sbin/containerd"],
            into: rootfsDir
        )
        try writeRuntimeBinaryWrapper(
            name: "msl-runtime-buildkitd",
            candidates: ["/usr/bin/buildkitd", "/usr/sbin/buildkitd"],
            into: rootfsDir
        )
        try writeRuntimeBinaryWrapper(
            name: "msl-runtime-runc",
            candidates: ["/usr/bin/runc", "/usr/sbin/runc"],
            into: rootfsDir
        )
        try writeRuntimeBinaryWrapper(
            name: "msl-runtime-youki",
            candidates: ["/usr/bin/youki", "/usr/local/bin/youki", "/usr/bin/runc", "/usr/sbin/runc"],
            into: rootfsDir
        )
        try writeRuntimeBinaryWrapper(
            name: "buildctl",
            candidates: ["/usr/local/bin/buildctl-real", "/usr/bin/buildctl", "/usr/sbin/buildctl", "/sbin/buildctl"],
            into: rootfsDir
        )
        try writeRuntimeBinaryWrapper(
            name: "iptables",
            candidates: ["/usr/sbin/iptables", "/sbin/iptables", "/usr/bin/iptables"],
            into: rootfsDir
        )
        try writeRuntimeBinaryWrapper(
            name: "ip6tables",
            candidates: ["/usr/sbin/ip6tables", "/sbin/ip6tables", "/usr/bin/ip6tables"],
            into: rootfsDir
        )
        try writeRuntimeBinaryWrapper(
            name: "iptables-save",
            candidates: ["/usr/sbin/iptables-save", "/sbin/iptables-save", "/usr/bin/iptables-save"],
            into: rootfsDir
        )
        try writeRuntimeBinaryWrapper(
            name: "iptables-restore",
            candidates: ["/usr/sbin/iptables-restore", "/sbin/iptables-restore", "/usr/bin/iptables-restore"],
            into: rootfsDir
        )
        try writeRuntimeBinaryWrapper(
            name: "ip6tables-save",
            candidates: ["/usr/sbin/ip6tables-save", "/sbin/ip6tables-save", "/usr/bin/ip6tables-save"],
            into: rootfsDir
        )
        try writeRuntimeBinaryWrapper(
            name: "ip6tables-restore",
            candidates: ["/usr/sbin/ip6tables-restore", "/sbin/ip6tables-restore", "/usr/bin/ip6tables-restore"],
            into: rootfsDir
        )
        try writeExecutableScript(
            """
            #!/bin/sh
            set -eu
            state_root=/run/msl/state-root
            uuid="$(blkid -s UUID -o value /dev/vdb 2>/dev/null || true)"
            [ -n "$uuid" ] || uuid=msl-state
            dedupe_home=/var/lib/msl-btrfs-dedupe/$uuid
            hash_file="$dedupe_home/duperemove.hash"
            [ -d "$state_root" ] || {
              echo "msl-btrfs-dedupe: missing state root $state_root" >&2
              exit 1
            }
            command -v duperemove >/dev/null 2>&1 || {
              echo "msl-btrfs-dedupe: duperemove not found; rebuild container runtime with dedupe support" >&2
              exit 1
            }
            mkdir -p "$dedupe_home"
            while true; do
              nice -n 10 duperemove -r -d -q --hashfile="$hash_file" --io-threads=1 --cpu-threads=1 "$state_root/upper" "$state_root/work" >/var/log/msl-btrfs-dedupe.log 2>&1 || true
              sleep 900
            done
            """,
            to: rootfsDir.appendingPathComponent("usr/local/bin/msl-btrfs-dedupe", isDirectory: false)
        )

        try writeOpenRCService(
            name: "containerd",
            command: "/usr/local/bin/msl-runtime-containerd",
            commandArgs: "--config /etc/containerd/config.toml",
            pidfile: "/run/containerd/containerd.pid",
            dependencies: [
                "need localmount",
                "after bootmisc",
                "before buildkitd"
            ],
            startPre: [
                "checkpath --directory /run/containerd",
                "checkpath --directory /var/lib/containerd"
            ],
            into: rootfsDir
        )
        try writeOpenRCService(
            name: "buildkitd",
            command: "/usr/local/bin/msl-runtime-buildkitd",
            commandArgs: "--addr unix:///run/buildkit/buildkitd.sock --config /etc/buildkit/buildkitd.toml",
            pidfile: "/run/buildkit/buildkitd.pid",
            dependencies: [
                "need localmount containerd",
                "after containerd"
            ],
            startPre: [
                "checkpath --directory /run/buildkit",
                "checkpath --directory /var/lib/buildkit"
            ],
            into: rootfsDir
        )
        try writeOpenRCService(
            name: "msl-btrfs-dedupe",
            command: "/usr/local/bin/msl-btrfs-dedupe",
            commandArgs: "",
            pidfile: "/run/msl-btrfs-dedupe.pid",
            dependencies: [
                "need localmount",
                "after bootmisc",
                "before containerd buildkitd"
            ],
            startPre: [
                "checkpath --directory /var/lib/msl-btrfs-dedupe",
                "checkpath --directory /run/msl/state-root"
            ],
            into: rootfsDir
        )

        try ensureRunlevelLink(service: "msl-btrfs-dedupe", rootfsDir: rootfsDir)
        try ensureRunlevelLink(service: "containerd", rootfsDir: rootfsDir)
        try ensureRunlevelLink(service: "buildkitd", rootfsDir: rootfsDir)
    }

    private func writeRuntimeBinaryWrapper(name: String, candidates: [String], into rootfsDir: URL) throws {
        let resolution = candidates.map { "  if [ -x \"\($0)\" ]; then exec \"\($0)\" \"$@\"; fi" }.joined(separator: "\n")
        try writeExecutableScript(
            """
            #!/bin/sh
            \(resolution)
            echo "\(name): no runtime binary found" >&2
            exit 127
            """,
            to: rootfsDir.appendingPathComponent("usr/local/bin/\(name)", isDirectory: false)
        )
    }

    private func writeOpenRCService(
        name: String,
        command: String,
        commandArgs: String,
        pidfile: String,
        dependencies: [String],
        startPre: [String],
        into rootfsDir: URL
    ) throws {
        let dependencyBody = dependencies.joined(separator: "\n    ")
        let startPreBody = startPre.joined(separator: "\n  ")
        try writeExecutableScript(
            """
            #!/sbin/openrc-run
            name="\(name)"
            description="\(name) service"
            command="\(command)"
            command_args="\(commandArgs)"
            command_background="yes"
            pidfile="\(pidfile)"
            supervisor=supervise-daemon
            respawn_delay=1
            respawn_max=0
            respawn_period=0

            depend() {
                \(dependencyBody)
            }

            start_pre() {
              \(startPreBody)
            }
            """,
            to: rootfsDir.appendingPathComponent("etc/init.d/\(name)", isDirectory: false)
        )
    }

    private func ensureRunlevelLink(service: String, rootfsDir: URL) throws {
        let runlevelLink = rootfsDir.appendingPathComponent("etc/runlevels/default/\(service)", isDirectory: false)
        if fileManager.fileExists(atPath: runlevelLink.path) {
            try fileManager.removeItem(at: runlevelLink)
        }
        try fileManager.createSymbolicLink(atPath: runlevelLink.path, withDestinationPath: "/etc/init.d/\(service)")
    }

    private func writeExecutableScript(_ text: String, to url: URL) throws {
        try writeText(text, to: url)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func writeText(_ text: String, to url: URL) throws {
        try ensureDir(url.deletingLastPathComponent())
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    private func installGuestRuntimeServiceContracts(rootfsDir: URL, serviceManager rawServiceManager: String) throws {
        let serviceManager = rawServiceManager.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        logger.log("guest_service_contract_install_started", fields: [
            "service_manager": serviceManager,
            "rootfs": rootfsDir.path
        ])
        switch serviceManager {
        case "systemd":
            try installSystemdMSLInitService(rootfsDir: rootfsDir)
            try configureSystemdTimesyncdUpstream(rootfsDir: rootfsDir)
        case "openrc":
            try installOpenRCMSLInitService(rootfsDir: rootfsDir)
            try configureOpenRCNTPUpstream(rootfsDir: rootfsDir)
        default:
            throw MSLRuntimeError("unsupported runtimeProfile.serviceManager '\(rawServiceManager)'")
        }
        logger.log("guest_service_contract_install_completed", fields: [
            "service_manager": serviceManager,
            "rootfs": rootfsDir.path
        ])
    }

    private func installSystemdMSLInitService(rootfsDir: URL) throws {
        let unitDir = rootfsDir.appendingPathComponent("etc/systemd/system", isDirectory: true)
        try fileManager.createDirectory(at: unitDir, withIntermediateDirectories: true)

        let unitFile = unitDir.appendingPathComponent("msl-init.service", isDirectory: false)
        let unitText = """
        [Unit]
        Description=msl init control server
        After=network.target local-fs.target
        Before=docker.service containerd.service

        [Service]
        Type=simple
        Environment=MSL_VSOCK_PORT=1024
        Environment=MSL_INIT_LOG_FILE=/var/log/msl-init.log
        ExecStart=/usr/local/bin/msl-init-bootloader
        Restart=always
        RestartSec=1

        [Install]
        WantedBy=multi-user.target
        """
        try Data(unitText.utf8).write(to: unitFile, options: .atomic)

        let wantsDir = unitDir.appendingPathComponent("multi-user.target.wants", isDirectory: true)
        try fileManager.createDirectory(at: wantsDir, withIntermediateDirectories: true)
        let wantsLink = wantsDir.appendingPathComponent("msl-init.service", isDirectory: false)
        if fileManager.fileExists(atPath: wantsLink.path) {
            try fileManager.removeItem(at: wantsLink)
        }
        try fileManager.createSymbolicLink(
            atPath: wantsLink.path,
            withDestinationPath: "../msl-init.service"
        )
        logger.log("init_service_contract_staged", fields: [
            "service_manager": "systemd",
            "unit": unitFile.path,
            "enable_link": wantsLink.path
        ])
    }

    private func configureSystemdTimesyncdUpstream(rootfsDir: URL) throws {
        let confDir = rootfsDir.appendingPathComponent("etc/systemd/timesyncd.conf.d", isDirectory: true)
        try fileManager.createDirectory(at: confDir, withIntermediateDirectories: true)
        let confFile = confDir.appendingPathComponent("90-msl.conf", isDirectory: false)
        let confText = """
        [Time]
        NTP=127.0.0.1
        FallbackNTP=
        """
        try Data(confText.utf8).write(to: confFile, options: .atomic)
        logger.log("ntp_upstream_config_applied", fields: [
            "service_manager": "systemd",
            "client": "systemd-timesyncd",
            "upstream": "127.0.0.1",
            "config": confFile.path
        ])

        // Keep distro default enablement, but ensure timesyncd is enabled when unit file exists.
        let unitCandidates = [
            rootfsDir.appendingPathComponent("lib/systemd/system/systemd-timesyncd.service", isDirectory: false),
            rootfsDir.appendingPathComponent("usr/lib/systemd/system/systemd-timesyncd.service", isDirectory: false)
        ]
        guard let unitPath = unitCandidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            logger.log("ntp_upstream_enable_skipped", fields: [
                "service_manager": "systemd",
                "reason": "timesyncd_unit_missing"
            ])
            return
        }
        let wantsDir = rootfsDir.appendingPathComponent("etc/systemd/system/sysinit.target.wants", isDirectory: true)
        try fileManager.createDirectory(at: wantsDir, withIntermediateDirectories: true)
        let wantsLink = wantsDir.appendingPathComponent("systemd-timesyncd.service", isDirectory: false)
        if fileManager.fileExists(atPath: wantsLink.path) {
            try fileManager.removeItem(at: wantsLink)
        }
        let relative = unitPath.path.replacingOccurrences(of: rootfsDir.path, with: "")
        try fileManager.createSymbolicLink(atPath: wantsLink.path, withDestinationPath: relative)
        logger.log("ntp_upstream_enable_applied", fields: [
            "service_manager": "systemd",
            "client": "systemd-timesyncd",
            "enable_link": wantsLink.path
        ])
    }

    private func installOpenRCMSLInitService(rootfsDir: URL) throws {
        let initDir = rootfsDir.appendingPathComponent("etc/init.d", isDirectory: true)
        try fileManager.createDirectory(at: initDir, withIntermediateDirectories: true)
        let serviceFile = initDir.appendingPathComponent("msl-init", isDirectory: false)
        let serviceText = """
        #!/sbin/openrc-run
        name="msl-init"
        description="msl init control server"
        command="/usr/local/bin/msl-init-bootloader"
        command_background="yes"
        pidfile="/run/msl-init.pid"
        output_log="/var/log/msl-init.log"
        error_log="/var/log/msl-init.log"
        supervisor=supervise-daemon
        respawn_delay=1
        respawn_max=0
        respawn_period=0

        depend() {
            need localmount
            after bootmisc
            before docker
        }

        start_pre() {
            checkpath --file --mode 0644 /var/log/msl-init.log
        }
        """
        try Data(serviceText.utf8).write(to: serviceFile, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: serviceFile.path)

        let runlevelDir = rootfsDir.appendingPathComponent("etc/runlevels/default", isDirectory: true)
        try fileManager.createDirectory(at: runlevelDir, withIntermediateDirectories: true)
        let runlevelLink = runlevelDir.appendingPathComponent("msl-init", isDirectory: false)
        if fileManager.fileExists(atPath: runlevelLink.path) {
            try fileManager.removeItem(at: runlevelLink)
        }
        try fileManager.createSymbolicLink(atPath: runlevelLink.path, withDestinationPath: "/etc/init.d/msl-init")
        logger.log("init_service_contract_staged", fields: [
            "service_manager": "openrc",
            "service": serviceFile.path,
            "runlevel_link": runlevelLink.path
        ])
    }

    private func configureOpenRCNTPUpstream(rootfsDir: URL) throws {
        let confDir = rootfsDir.appendingPathComponent("etc/conf.d", isDirectory: true)
        try fileManager.createDirectory(at: confDir, withIntermediateDirectories: true)
        let ntpdConf = confDir.appendingPathComponent("ntpd", isDirectory: false)
        let ntpdText = """
        NTPD_OPTS="-p 127.0.0.1"
        """
        try Data(ntpdText.utf8).write(to: ntpdConf, options: .atomic)
        logger.log("ntp_upstream_config_applied", fields: [
            "service_manager": "openrc",
            "client": "ntpd",
            "upstream": "127.0.0.1",
            "config": ntpdConf.path
        ])
    }

    private func normalizeRootFstabForVirtualDisk(rootfsDir: URL) throws {
        let fstab = rootfsDir.appendingPathComponent("etc/fstab", isDirectory: false)
        guard fileManager.fileExists(atPath: fstab.path) else {
            return
        }
        let original = try String(contentsOf: fstab, encoding: .utf8)
        let normalized = normalizeRootFstabText(original)
        guard normalized.changed else {
            return
        }
        try Data(normalized.text.utf8).write(to: fstab, options: .atomic)
        logger.log("guest_fstab_root_source_normalized", fields: [
            "path": fstab.path,
            "from": normalized.originalRootSource ?? "unknown",
            "to": "/dev/vda (nodiscard)"
        ])
    }

    private func normalizeRootFstabText(_ text: String) -> (text: String, changed: Bool, originalRootSource: String?) {
        let endsWithNewline = text.hasSuffix("\n")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var changed = false
        var originalRootSource: String?
        var normalizedRootWritten = false
        var out: [String] = []
        out.reserveCapacity(lines.count)

        for raw in lines {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                out.append(line)
                continue
            }

            let commentIndex = line.firstIndex(of: "#")
            let head = commentIndex.map { String(line[..<$0]) } ?? line
            let tail = commentIndex.map { String(line[$0...]) } ?? ""
            let parts = head.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2 else {
                out.append(line)
                continue
            }

            if parts[1] == "/" {
                if !changed {
                    originalRootSource = parts[0]
                }
                if !normalizedRootWritten {
                    let normalizedRoot = "/dev/vda\t/\tauto\tdefaults,nodiscard\t0\t1"
                    let rebuilt = parts.joined(separator: "\t")
                    if rebuilt != normalizedRoot || !tail.isEmpty {
                        changed = true
                    }
                    out.append(normalizedRoot)
                    normalizedRootWritten = true
                } else {
                    changed = true
                }
                continue
            }
            out.append(line)
        }

        var normalized = out.joined(separator: "\n")
        if endsWithNewline {
            normalized += "\n"
        }
        return (normalized, changed, originalRootSource)
    }

    internal func resolveExt4MkfsHelperExecutable() -> String? {
        resolveHostToolExecutable(
            explicitEnv: "MSL_EXT4_MKFS_HELPER_PATH",
            stagedPath: paths.mslHostExt4MkfsHelperBinaryFile.path,
            binaryName: "msl-ext4-mkfs",
            supportDirName: "msl-ext4-mkfs"
        )
    }

    internal func resolveExt4HelperExecutable() -> String? {
        resolveHostToolExecutable(
            explicitEnv: "MSL_EXT4_HELPER_PATH",
            stagedPath: paths.mslHostExt4HelperBinaryFile.path,
            binaryName: "msl-ext4-image",
            supportDirName: "msl-ext4-image"
        )
    }

    private func resolveHostToolExecutable(
        explicitEnv: String,
        stagedPath: String,
        binaryName: String,
        supportDirName: String
    ) -> String? {
        if let explicit = ProcessInfo.processInfo.environment[explicitEnv], !explicit.isEmpty,
           fileManager.isExecutableFile(atPath: explicit) {
            return explicit
        }

        var candidates: [String] = []
        candidates.append(stagedPath)

        var roots: [URL] = []
        roots.append(URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true))
        if let arg0 = CommandLine.arguments.first {
            roots.append(URL(fileURLWithPath: arg0, isDirectory: false).deletingLastPathComponent())
        }
        for root in roots {
            candidates.append(root.appendingPathComponent(binaryName, isDirectory: false).path)
            var cursor = root
            for _ in 0..<8 {
                candidates.append(
                    cursor
                        .appendingPathComponent("Support", isDirectory: true)
                        .appendingPathComponent(supportDirName, isDirectory: true)
                        .appendingPathComponent("target", isDirectory: true)
                        .appendingPathComponent("release", isDirectory: true)
                        .appendingPathComponent(binaryName, isDirectory: false)
                        .path
                )
                let parent = cursor.deletingLastPathComponent()
                if parent.path == cursor.path {
                    break
                }
                cursor = parent
            }
        }

        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return process.findExecutable([binaryName])
    }

    internal func validateTarArchiveEntries(_ archiveURL: URL) throws {
        let tarRes = try process.run("/usr/bin/tar", ["-tf", archiveURL.path], captureOutput: true)
        guard tarRes.exitCode == 0 else {
            throw MSLRuntimeError("failed to inspect tar archive: \(archiveURL.path)")
        }
        for line in tarRes.stdout.split(separator: "\n") {
            let path = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if path.isEmpty { continue }
            if !Self.isSafeTarEntryPath(path) {
                throw MSLRuntimeError("unsafe tar entry path detected: \(path)")
            }
        }
    }

    internal static func isSafeTarEntryPath(_ path: String) -> Bool {
        if path.hasPrefix("/") { return false }
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        for part in normalized.split(separator: "/") {
            if part == ".." { return false }
        }
        return true
    }

    internal func extractTarArchive(_ archiveURL: URL, to destinationDir: URL) throws {
        let baseArgs = [
            "-xf", archiveURL.path,
            "-C", destinationDir.path,
            "--no-same-owner",
            "--no-same-permissions"
        ]
        let first = try process.run("/usr/bin/tar", baseArgs, captureOutput: true)
        if first.exitCode == 0 {
            return
        }

        // Retry once excluding /dev entries (device nodes are recreated by devtmpfs in guest).
        try? fileManager.removeItem(at: destinationDir)
        try ensureDir(destinationDir)
        let retryArgs = baseArgs + ["--exclude", "dev/*", "--exclude", "./dev/*"]
        let second = try process.run("/usr/bin/tar", retryArgs, captureOutput: true)
        if second.exitCode == 0 {
            return
        }

        throw MSLRuntimeError(
            "failed to extract tar archive: \(archiveURL.lastPathComponent)\n" +
            "tar stderr(first): \(first.nonEmptyErrorOutput.prefix(400))\n" +
            "tar stderr(retry): \(second.nonEmptyErrorOutput.prefix(400))"
        )
    }

    private func validateInstanceName(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw MSLRuntimeError("instance name is required")
        }
        if trimmed.count > 64 {
            throw MSLRuntimeError("instance name must be <= 64 characters")
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        if !trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            throw MSLRuntimeError("instance name may contain only [A-Za-z0-9-_.]")
        }
        return trimmed
    }

    private func ensureDir(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func download(_ url: URL, to destination: URL) throws {
        let interactiveTTY = isatty(STDERR_FILENO) == 1
        let startedAt = Date()
        let progress = DownloadProgressRenderer(
            enabled: interactiveTTY,
            label: destination.lastPathComponent
        )
        let observer = DownloadTaskObserver(onStart: { expected in
            if interactiveTTY {
                return
            }
            let totalText = expected > 0 ? formatByteCount(expected) : "unknown"
            fputs("downloading: \(destination.lastPathComponent) size: \(totalText)\n", stderr)
            fflush(stderr)
        }, onProgress: { written, expected in
            if interactiveTTY {
                progress.update(written: written, total: expected)
            }
        })
        let session = URLSession(configuration: .ephemeral, delegate: observer, delegateQueue: nil)
        let task = session.downloadTask(with: url)
        task.resume()
        observer.waitUntilDone()
        session.finishTasksAndInvalidate()

        if !interactiveTTY && !observer.startSignaled {
            let totalText = observer.bytesExpected > 0 ? formatByteCount(observer.bytesExpected) : "unknown"
            fputs("downloading: \(destination.lastPathComponent) size: \(totalText)\n", stderr)
            fflush(stderr)
        }

        progress.finish(written: observer.bytesWritten, total: observer.bytesExpected, success: observer.error == nil)

        if !interactiveTTY {
            let elapsedSec = max(Date().timeIntervalSince(startedAt), 0.001)
            let downloadedBytes = max(observer.bytesWritten, 0)
            let avgBytesPerSec = Double(downloadedBytes) / elapsedSec
            let elapsedText = String(format: "%.2fs", elapsedSec)
            let downloadedText = formatByteCount(downloadedBytes)
            let avgSpeedText = formatByteCount(Int64(avgBytesPerSec)) + "/s"
            fputs(
                "downloaded: \(destination.lastPathComponent) \(downloadedText) in \(elapsedText) (avg \(avgSpeedText))\n",
                stderr
            )
            fflush(stderr)
        }

        if let transferError = observer.error {
            throw MSLRuntimeError("download failed for \(url.absoluteString): \(transferError)")
        }
        if let statusCode = observer.httpStatusCode,
           !Self.isSuccessfulHTTPStatus(statusCode) {
            throw MSLRuntimeError("download failed for \(url.absoluteString): HTTP \(statusCode)")
        }
        guard let tmpURL = observer.downloadedFileURL else {
            throw MSLRuntimeError("download failed: no temporary file for \(url.absoluteString)")
        }
        do {
            if self.fileManager.fileExists(atPath: destination.path) {
                try self.fileManager.removeItem(at: destination)
            }
            try self.fileManager.moveItem(at: tmpURL, to: destination)
        } catch {
            throw MSLRuntimeError("download failed for \(url.absoluteString): \(error)")
        }
    }

    internal func computeSHA256(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = handle.readData(ofLength: 1024 * 1024)
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    internal static func isSuccessfulHTTPStatus(_ statusCode: Int) -> Bool {
        (200..<300).contains(statusCode)
    }

    private func normalizeFingerprint(_ value: String) -> String {
        value
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\t", with: "")
            .uppercased()
    }

    private func loadInstanceSourceRecord(name: String) throws -> DistributionSourceRecord? {
        let metadataURL = paths.distroMetadataFile(named: name)
        if fileManager.fileExists(atPath: metadataURL.path),
           let metadata = try? readJSON(DistributionInstanceMetadata.self, from: metadataURL) {
            return metadata.source
        }

        let sourceURL = paths.distroSourceFile(named: name)
        if fileManager.fileExists(atPath: sourceURL.path),
           let source = try? readJSON(DistributionSourceRecord.self, from: sourceURL) {
            return source
        }
        return nil
    }

    private func resolveCacheDirectory(for source: DistributionSourceRecord) -> URL? {
        if source.sourceType == "manifest" {
            if let distro = source.distro, let version = source.version, let arch = source.arch {
                return paths.cacheDownloadsDir
                    .appendingPathComponent(distro, isDirectory: true)
                    .appendingPathComponent(version, isDirectory: true)
                    .appendingPathComponent(arch, isDirectory: true)
            }
            if let manifestID = source.manifestId,
               let entry = manifestStore.allEntries().first(where: { $0.id == manifestID }) {
                return paths.cacheDownloadsDir
                    .appendingPathComponent(entry.distro, isDirectory: true)
                    .appendingPathComponent(entry.version, isDirectory: true)
                    .appendingPathComponent(entry.arch, isDirectory: true)
            }
            return nil
        }

        if source.sourceType == "local", !source.sha256.isEmpty {
            let short = String(source.sha256.prefix(12))
            return paths.cacheDownloadsDir
                .appendingPathComponent("local", isDirectory: true)
                .appendingPathComponent(short, isDirectory: true)
        }
        if source.sourceType == "container-remote",
           let registry = source.registry,
           let repository = source.repository,
           let digest = (source.digest?.isEmpty == false ? source.digest : (source.sha256.isEmpty ? nil : source.sha256)) {
            return containerCacheBaseDirectory(
                registry: registry,
                repository: repository,
                digest: sanitizeDigestForPath(digest)
            )
        }
        return nil
    }

    func migrateLegacyRootfsCacheIfNeeded() throws {
        let legacyDownloads = paths.legacyCacheDownloadsDir
        let legacyStaging = paths.legacyCacheStagingDir
        let newDownloads = paths.cacheDownloadsDir
        let newStaging = paths.cacheStagingDir

        let hasLegacyDownloads = fileManager.fileExists(atPath: legacyDownloads.path)
        let hasLegacyStaging = fileManager.fileExists(atPath: legacyStaging.path)
        guard hasLegacyDownloads || hasLegacyStaging else {
            return
        }

        try ensureDir(paths.cacheDir)

        if hasLegacyDownloads, !fileManager.fileExists(atPath: newDownloads.path) {
            try fileManager.moveItem(at: legacyDownloads, to: newDownloads)
            logger.log("cache_layout_migrated", fields: [
                "from": legacyDownloads.path,
                "to": newDownloads.path
            ])
        }

        if hasLegacyStaging, !fileManager.fileExists(atPath: newStaging.path) {
            try fileManager.moveItem(at: legacyStaging, to: newStaging)
            logger.log("cache_layout_migrated", fields: [
                "from": legacyStaging.path,
                "to": newStaging.path
            ])
        }

        if fileManager.fileExists(atPath: paths.legacyCacheDir.path),
           let entries = try? fileManager.contentsOfDirectory(atPath: paths.legacyCacheDir.path),
           entries.isEmpty {
            try? fileManager.removeItem(at: paths.legacyCacheDir)
        }
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(type, from: data)
    }

    private func emitStatus(_ message: String) {
        fputs("\(message)\n", stderr)
        fflush(stderr)
    }
}

private extension ProcessResult {
    var nonEmptyErrorOutput: String {
        let trimmedErr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedErr.isEmpty {
            return trimmedErr
        }
        let trimmedOut = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedOut.isEmpty {
            return trimmedOut
        }
        return "<empty>"
    }
}

private final class DownloadTaskObserver: NSObject, URLSessionDownloadDelegate {
    private let semaphore = DispatchSemaphore(value: 0)
    private let onStart: (Int64) -> Void
    private let onProgress: (Int64, Int64) -> Void
    private var lastEmitNs: UInt64 = 0

    private(set) var downloadedFileURL: URL?
    private(set) var error: Error?
    private(set) var httpStatusCode: Int?
    private(set) var bytesWritten: Int64 = 0
    private(set) var bytesExpected: Int64 = NSURLSessionTransferSizeUnknown
    private(set) var startSignaled: Bool = false

    init(onStart: @escaping (Int64) -> Void, onProgress: @escaping (Int64, Int64) -> Void) {
        self.onStart = onStart
        self.onProgress = onProgress
    }

    func waitUntilDone() {
        semaphore.wait()
    }

    func urlSession(
        _: URLSession,
        downloadTask _: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        bytesWritten = totalBytesWritten
        bytesExpected = totalBytesExpectedToWrite

        if !startSignaled {
            startSignaled = true
            onStart(totalBytesExpectedToWrite)
        }

        let now = DispatchTime.now().uptimeNanoseconds
        let shouldEmitByInterval = now - lastEmitNs >= 100_000_000
        let shouldEmitByCompletion = totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite
        if shouldEmitByInterval || shouldEmitByCompletion {
            lastEmitNs = now
            onProgress(totalBytesWritten, totalBytesExpectedToWrite)
        }
    }

    func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        downloadedFileURL = location
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let response = task.response as? HTTPURLResponse {
            httpStatusCode = response.statusCode
        }
        self.error = error
        semaphore.signal()
    }
}

private final class DownloadProgressRenderer {
    private let enabled: Bool
    private let label: String
    private var lastWritten: Int64 = 0
    private var lastTotal: Int64 = NSURLSessionTransferSizeUnknown

    init(enabled: Bool, label: String) {
        self.enabled = enabled
        self.label = label
    }

    func update(written: Int64, total: Int64) {
        lastWritten = written
        lastTotal = total
        guard enabled else { return }
        let line = renderLine(prefix: "downloading", written: written, total: total)
        fputs("\u{001B}[2K\r\(line)", stderr)
        fflush(stderr)
    }

    func finish(written: Int64, total: Int64, success: Bool) {
        let finalWritten = max(written, lastWritten)
        let finalTotal = total == NSURLSessionTransferSizeUnknown ? lastTotal : total
        guard enabled else { return }

        let prefix = success ? "downloaded " : "download failed"
        let line = renderLine(prefix: prefix, written: finalWritten, total: finalTotal)
        fputs("\u{001B}[2K\r\(line)\n", stderr)
        fflush(stderr)
    }

    private func renderLine(prefix: String, written: Int64, total: Int64) -> String {
        if total > 0 {
            let pct = min(100.0, (Double(written) / Double(total)) * 100.0)
            return "\(prefix): \(label) \(formatByteCount(written))/\(formatByteCount(total)) (\(String(format: "%.1f", pct))%)"
        }
        return "\(prefix): \(label) \(formatByteCount(written))"
    }
}

private func formatByteCount(_ bytes: Int64) -> String {
    if bytes < 0 {
        return "unknown"
    }
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.includesUnit = true
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: bytes)
}
