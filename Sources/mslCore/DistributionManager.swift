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

final class DistributionManager {
    static let reservedInternalInstanceNames: Set<String> = ["_imagewriter"]

    private let paths: MSLPaths
    private let logger: MSLLogger
    private let fileManager: FileManager
    private let manifestStore: DistributionManifestStore
    private let process: ProcessExecutor

    init(
        paths: MSLPaths,
        logger: MSLLogger,
        fileManager: FileManager = .default,
        manifestStore: DistributionManifestStore = DistributionManifestStore(),
        process: ProcessExecutor = ProcessExecutor()
    ) {
        self.paths = paths
        self.logger = logger
        self.fileManager = fileManager
        self.manifestStore = manifestStore
        self.process = process
    }

    func installableDistributionNames() -> [String] {
        manifestStore.installableNames()
    }

    func installableDistributions() -> [DistributionInstallDescriptor] {
        manifestStore.installableDescriptors()
    }

    func installedInstances() -> [InstalledInstanceDescriptor] {
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
            let diskPath = paths.distroDiskFile(named: name)
            let metadataPath = paths.distroMetadataFile(named: name)

            var createdAt: Int64?
            if let metadata = try? readJSON(DistributionInstanceMetadata.self, from: metadataPath) {
                createdAt = metadata.createdAtEpochMs
            }

            let hasDisk = fileManager.fileExists(atPath: diskPath.path)
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
        return installedInstances().contains { $0.name == name && $0.hasDisk }
    }

    func runtimeMetadataURL(explicitInstanceName: String?, defaultInstanceName: String?) throws -> URL {
        if let explicit = explicitInstanceName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            guard let metadata = runtimeMetadataURLIfBootable(instanceName: explicit) else {
                throw MSLRuntimeError("instance '\(explicit)' not found. use `msl --list` to inspect installed instances.")
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
            "no bootable instance found. run `msl install --list` and install one with `msl install <distribution>`."
        )
    }

    func runtimeMetadataURL(defaultInstanceName: String?) throws -> URL {
        try runtimeMetadataURL(explicitInstanceName: nil, defaultInstanceName: defaultInstanceName)
    }

    private func runtimeMetadataURLIfBootable(instanceName: String) -> URL? {
        let metadata = paths.distroMetadataFile(named: instanceName)
        let disk = paths.distroDiskFile(named: instanceName)
        guard fileManager.fileExists(atPath: disk.path) else {
            return nil
        }
        return metadata
    }

    func isReservedInternalInstanceName(_ name: String) -> Bool {
        Self.reservedInternalInstanceNames.contains(name)
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
        force: Bool
    ) throws -> DistributionVerifiedRecord {
        let source = try resolveSource(targetAlias: targetAlias, localFilePath: localFilePath)
        switch source {
        case .manifest(let entry):
            return try fetchManifestEntry(entry, force: force)
        case .localFile(let url):
            return try cacheLocalFile(url, force: force)
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
        let source = try resolveSource(targetAlias: targetAlias, localFilePath: localFilePath)
        emitStatus("install: fetching rootfs archive")
        let verified = try fetch(targetAlias: targetAlias, localFilePath: localFilePath, force: false)

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
        emitStatus("install: injecting msl-init")
        let runtimeProfile = initialRuntimeProfile(for: source, instanceName: name)
        try stageInitBinary(intoRootfs: rootfsDir, runtimeProfile: runtimeProfile)

        emitStatus("install: creating ext4 disk image")
        try buildExt4Disk(
            from: rootfsDir,
            sourceArchive: tarballURL,
            outputDisk: diskFile,
            diskSizeGB: diskSizeGB ?? 8
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
            cacheSharing: initialCacheSharing
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
        rebuild: Bool,
        diskSizeGB: Int?,
        mslExecutablePath: String
    ) throws -> URL {
        try migrateLegacyRootfsCacheIfNeeded()
        let name = try validateInstanceName(rawName)
        emitStatus("install: preparing instance '\(name)'")
        let source = try resolveSource(targetAlias: targetAlias, localFilePath: localFilePath)
        emitStatus("install: fetching rootfs archive")
        let verified = try fetch(targetAlias: targetAlias, localFilePath: localFilePath, force: false)

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
            let tarballURL = URL(fileURLWithPath: verified.tarballPath)
            let imagewriterScript = try resolveImagewriterBuildScriptPath(mslExecutablePath: mslExecutablePath)
            let requestedSizeMB = max(0, (diskSizeGB ?? 0) * 1024)
            let initBinaryPath = try resolveImagewriterInitBinaryPath()

            emitStatus("install: creating btrfs disk image via imagewriter")
            didRunImagewriterBuild = true
            try runImagewriterBuild(
                scriptPath: imagewriterScript,
                mslExecutablePath: mslExecutablePath,
                rootfsTarballPath: tarballURL.path,
                outputDiskPath: diskFile.path,
                sizeMB: requestedSizeMB,
                initBinaryPath: initBinaryPath
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
            }

            let defaultKernelProfileRef = try? DefaultInstanceStore(paths: paths, fileManager: fileManager).loadDefaultKernelProfileRef()
            let env = ProcessInfo.processInfo.environment
            let envKernelRaw = env["MSL_KERNEL_PROFILE"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let envKernelProfileRef = (envKernelRaw?.isEmpty == false) ? envKernelRaw : nil
            let kernelProfileRef = envKernelProfileRef ?? defaultKernelProfileRef ?? "slim"
            let compressionPolicy = try resolveCompressionPolicyForInstall()
            compressionPolicyCount = compressionPolicy.pathPolicies.count
            let initialPolicy = initialUserConvergencePolicy(for: source)
            let initialCacheSharing = initialCacheSharingPolicy(for: source)
            let runtimeProfile = initialRuntimeProfile(for: source, instanceName: name)

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
                cacheSharing: initialCacheSharing
            )
            try writeJSON(sourceRecord, to: sourceFile)
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
            cacheSharing: initialCacheSharing
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
            if didMutate {
                try writeJSON(metadata, to: metadataURL)
            }
            return metadata
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

    internal func resolveSource(targetAlias: String?, localFilePath: String?) throws -> DistributionSourceSelection {
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

        guard let targetAlias, !targetAlias.isEmpty else {
            throw MSLRuntimeError("missing distribution target. use --distro <id> or --file <path>")
        }
        guard let entry = manifestStore.resolve(alias: targetAlias) else {
            throw MSLRuntimeError("unsupported distribution '\(targetAlias)'")
        }
        try manifestStore.validate(entry)
        return .manifest(entry)
    }

    private func initialUserConvergencePolicy(for source: DistributionSourceSelection) -> UserConvergencePolicy {
        switch source {
        case .manifest(let entry):
            return entry.userConvergenceTemplate ?? defaultPolicyTemplate(forManifestEntry: entry)
        case .localFile:
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
        case .localFile:
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

        if metadata.source.sourceType == "local" {
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
        case .localFile:
            canUseServiceManaged = false
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
        case .localFile:
            return nil
        }
    }

    private func resolveManifestDefaultInitMode(for source: DistributionSourceSelection) -> String? {
        switch source {
        case .manifest(let entry):
            return normalizeInitMode(entry.defaultInitMode)
        case .localFile:
            return nil
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
        rootfsTarballPath: String,
        outputDiskPath: String,
        sizeMB: Int,
        initBinaryPath: String
    ) throws {
        var env: [String: String] = [
            "MSL_BIN": mslExecutablePath,
            "IMAGEWRITER_CLEAN_DISTROS": "0",
            "IMAGEWRITER_FORCE_SETUP": "0",
            "IMAGE_FS": "btrfs",
            "ROOTFS_TARBALL": rootfsTarballPath,
            "OUTPUT_RAW": outputDiskPath,
            "IMAGE_SIZE_MB": String(sizeMB),
            "IMAGEWRITER_INIT_BINARY": initBinaryPath,
            "IMAGEWRITER_RUN_TIMEOUT": "900"
        ]
        if let mslHome = ProcessInfo.processInfo.environment["MSL_HOME"], !mslHome.isEmpty {
            env["MSL_HOME"] = mslHome
        }
        if let shareRoot = ProcessInfo.processInfo.environment["MSL_HOST_SHARE_ROOT"], !shareRoot.isEmpty {
            env["MSL_HOST_SHARE_ROOT"] = shareRoot
        }
        if let configuredInstance = ProcessInfo.processInfo.environment["MSL_IMAGEWRITER_INSTANCE"], !configuredInstance.isEmpty {
            env["IMAGEWRITER_INSTANCE"] = configuredInstance
        }

        let result = try process.run("/bin/sh", [scriptPath], captureOutput: false, environment: env)
        guard result.exitCode == 0 else {
            let stageHint: String
            switch result.exitCode {
            case 21:
                stageHint = "stage=stage1_ext4"
            case 22:
                stageHint = "stage=btrfs_build"
            case 23:
                stageHint = "stage=finalize"
            default:
                stageHint = "stage=unknown"
            }
            throw MSLRuntimeError(
                "imagewriter build failed (\(result.exitCode), \(stageHint)). see imagewriter logs/output above."
            )
        }
    }

    private func resolveImagewriterInstanceName() -> String {
        let envValue = ProcessInfo.processInfo.environment["MSL_IMAGEWRITER_INSTANCE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let envValue, !envValue.isEmpty {
            return envValue
        }
        return "_imagewriter"
    }

    private func stopImagewriterInstance(mslExecutablePath: String, instanceName: String) {
        do {
            let result = try process.run(
                mslExecutablePath,
                ["--instance", instanceName, "--stop"],
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

    private func resolveImagewriterInitBinaryPath() throws -> String {
        let envPath = ProcessInfo.processInfo.environment["MSL_INIT_BINARY_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sourcePath: String
        if let envPath, !envPath.isEmpty {
            sourcePath = envPath
        } else {
            sourcePath = paths.mslHostInitBinaryFile.path
        }

        guard fileManager.fileExists(atPath: sourcePath) else {
            throw MSLRuntimeError(
                "msl-init binary not found at \(sourcePath). run `make build-init` or set MSL_INIT_BINARY_PATH."
            )
        }
        return sourcePath
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
            )
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

        if !force,
           fileManager.fileExists(atPath: tarballPath.path),
           fileManager.fileExists(atPath: verifiedPath.path) {
            let existing = try readJSON(DistributionVerifiedRecord.self, from: verifiedPath)
            if existing.sha256.caseInsensitiveCompare(entry.sha256) == .orderedSame &&
               existing.manifestId == entry.id {
                logger.log("cache_hit", fields: ["id": entry.id, "path": tarballPath.path])
                emitStatus("install: using cached archive \(tarballFileName)")
                return existing
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
        let envPath = ProcessInfo.processInfo.environment["MSL_INIT_BINARY_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sourcePath: String
        if let envPath, !envPath.isEmpty {
            sourcePath = envPath
        } else {
            sourcePath = paths.mslHostInitBinaryFile.path
        }

        guard fileManager.fileExists(atPath: sourcePath) else {
            throw MSLRuntimeError(
                "msl-init binary not found at \(sourcePath). run `make build-init` or set MSL_INIT_BINARY_PATH."
            )
        }

        let sourceURL = URL(fileURLWithPath: sourcePath)
        let destinations = [
            rootfsDir.appendingPathComponent("sbin/msl-init", isDirectory: false),
            rootfsDir.appendingPathComponent("usr/local/bin/msl-init", isDirectory: false)
        ]
        for dst in destinations {
            try fileManager.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: dst.path) {
                try fileManager.removeItem(at: dst)
            }
            try fileManager.copyItem(at: sourceURL, to: dst)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
        }

        let guestMSL = rootfsDir.appendingPathComponent("usr/local/bin/msl", isDirectory: false)
        if fileManager.fileExists(atPath: guestMSL.path) {
            try fileManager.removeItem(at: guestMSL)
        }
        try fileManager.createSymbolicLink(atPath: guestMSL.path, withDestinationPath: "msl-init")
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
        ExecStart=/usr/local/bin/msl-init
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
        command="/usr/local/bin/msl-init"
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
            "to": "/dev/vda"
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
                    let normalizedRoot = "/dev/vda\t/\tauto\tdefaults\t0\t1"
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

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
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
