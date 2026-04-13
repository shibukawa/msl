import Foundation
import Darwin

public struct MSLPaths {
    public let home: URL
    public let mslHome: URL
    public let mslSystemHome: URL
    public let appSupport: URL
    public let appRuntime: URL
    public let runtimeRoot: URL
    public let runtime: URL
    public let logs: URL
    public let appLogs: URL
    public let appControl: URL
    public let managerSocketFile: URL
    public let managerStateFile: URL
    public let lockFile: URL
    public let stateFile: URL
    public let sessionsFile: URL
    public let portsFile: URL
    public let runtimeControlSocketFile: URL
    public let runtimeEventSocketFile: URL
    public let initChannelSocketFile: URL
    public let initChannelHandoffFile: URL
    public let initChannelAckFile: URL
    public let configFile: URL
    public let imagesDir: URL
    public let distrosDir: URL
    public let cacheDir: URL
    public let legacyCacheDir: URL
    public let compressionCachePolicyCatalogFile: URL
    public let storageProvisionScriptFile: URL
    public let cacheDownloadsDir: URL
    public let cacheStagingDir: URL
    public let legacyCacheDownloadsDir: URL
    public let legacyCacheStagingDir: URL
    public let kernelsDir: URL
    public let sshDir: URL
    public let sshSharedConfigFile: URL
    public let sshInstancesDir: URL
    public let sshHostKeyFile: URL
    public let sshHostKnownHostsFile: URL
    public let bootstrapArtifactsDir: URL
    public let bootstrapCloudInitDir: URL
    public let bootstrapCloudInitUserDataFile: URL
    public let bootstrapCloudInitMetaDataFile: URL
    public let bootstrapCloudInitSeedISOFile: URL
    public let mslHostToolsDir: URL
    public let bundledContainerToolsStageDir: URL
    public let mslHostContainerToolsDir: URL
    public let mslHostExt4MkfsHelperBinaryFile: URL
    public let mslHostInitBinaryFile: URL
    public let mslHostInitBootloaderBinaryFile: URL
    public let mslHostExt4HelperBinaryFile: URL
    public let mslHostInitBootstrapLogFile: URL
    public let serialConsoleLogFile: URL

    public init(fileManager: FileManager = .default) {
        self.init(homeDirectoryURL: fileManager.homeDirectoryForCurrentUser, runtimeRootURL: nil)
    }

    public init(homeDirectoryURL: URL, runtimeRootURL: URL? = nil) {
        self.home = homeDirectoryURL
        self.mslHome = homeDirectoryURL.appendingPathComponent("msl-home", isDirectory: true)
        self.mslSystemHome = homeDirectoryURL.appendingPathComponent(".msl-system", isDirectory: true)
        self.appSupport = homeDirectoryURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("msl", isDirectory: true)
        self.appRuntime = appSupport.appendingPathComponent("runtime", isDirectory: true)
        self.runtimeRoot = runtimeRootURL ?? appRuntime
        self.runtime = runtimeRoot
        self.logs = runtime.appendingPathComponent("logs", isDirectory: true)
        self.appLogs = appSupport.appendingPathComponent("logs", isDirectory: true)
        self.appControl = appSupport.appendingPathComponent("app", isDirectory: true)
        self.managerSocketFile = appControl.appendingPathComponent("manager.sock", isDirectory: false)
        self.managerStateFile = appControl.appendingPathComponent("manager-state.json", isDirectory: false)
        self.lockFile = runtime.appendingPathComponent("lock", isDirectory: false)
        self.stateFile = runtime.appendingPathComponent("state.json", isDirectory: false)
        self.sessionsFile = runtime.appendingPathComponent("sessions.json", isDirectory: false)
        self.portsFile = runtime.appendingPathComponent("ports.json", isDirectory: false)
        self.runtimeControlSocketFile = runtime.appendingPathComponent("control.sock", isDirectory: false)
        self.runtimeEventSocketFile = runtime.appendingPathComponent("events.sock", isDirectory: false)
        self.mslHostToolsDir = mslSystemHome
        self.bundledContainerToolsStageDir = appSupport
            .appendingPathComponent("tools", isDirectory: true)
            .appendingPathComponent("bundled", isDirectory: true)
            .appendingPathComponent("darwin-arm64", isDirectory: true)
        self.mslHostContainerToolsDir = mslHostToolsDir.appendingPathComponent("tools", isDirectory: true)
        self.mslHostExt4MkfsHelperBinaryFile = mslHostToolsDir.appendingPathComponent("msl-ext4-mkfs", isDirectory: false)
        self.mslHostInitBinaryFile = mslHostToolsDir.appendingPathComponent("msl-init", isDirectory: false)
        self.mslHostInitBootloaderBinaryFile = mslHostToolsDir.appendingPathComponent("msl-init-bootloader", isDirectory: false)
        self.mslHostExt4HelperBinaryFile = mslHostToolsDir.appendingPathComponent("msl-ext4-image", isDirectory: false)
        self.mslHostInitBootstrapLogFile = mslHostToolsDir.appendingPathComponent("init-bootstrap.log", isDirectory: false)
        self.serialConsoleLogFile = logs.appendingPathComponent("serial-console.log", isDirectory: false)
        let uid = getuid()
        self.initChannelSocketFile = URL(fileURLWithPath: "/tmp/msl-init-\(uid).sock", isDirectory: false)
        self.initChannelHandoffFile = mslHostToolsDir.appendingPathComponent("init-channel-handoff.json", isDirectory: false)
        self.initChannelAckFile = mslHostToolsDir.appendingPathComponent("init-channel-ack.json", isDirectory: false)
        self.configFile = appSupport.appendingPathComponent("config.json", isDirectory: false)
        self.imagesDir = appSupport.appendingPathComponent("images", isDirectory: true)
        self.distrosDir = appSupport.appendingPathComponent("distros", isDirectory: true)
        self.cacheDir = appSupport.appendingPathComponent("caches", isDirectory: true)
        self.legacyCacheDir = appSupport.appendingPathComponent("cache", isDirectory: true)
        self.compressionCachePolicyCatalogFile = appSupport.appendingPathComponent("compression-cache-policy-catalog.json", isDirectory: false)
        self.storageProvisionScriptFile = appSupport.appendingPathComponent("storage-provision.sh", isDirectory: false)
        self.cacheDownloadsDir = cacheDir.appendingPathComponent("rootfs", isDirectory: true)
        self.cacheStagingDir = cacheDir.appendingPathComponent("staging", isDirectory: true)
        self.legacyCacheDownloadsDir = legacyCacheDir.appendingPathComponent("downloads", isDirectory: true)
        self.legacyCacheStagingDir = legacyCacheDir.appendingPathComponent("staging", isDirectory: true)
        self.kernelsDir = appSupport.appendingPathComponent("kernels", isDirectory: true)
        self.sshDir = appSupport.appendingPathComponent("ssh", isDirectory: true)
        self.sshSharedConfigFile = sshDir.appendingPathComponent("config", isDirectory: false)
        self.sshInstancesDir = sshDir.appendingPathComponent("instances", isDirectory: true)
        self.sshHostKeyFile = sshDir.appendingPathComponent("host-ed25519.key", isDirectory: false)
        self.sshHostKnownHostsFile = sshDir.appendingPathComponent("host-known_hosts", isDirectory: false)
        self.bootstrapArtifactsDir = appSupport.appendingPathComponent("bootstrap", isDirectory: true)
        self.bootstrapCloudInitDir = bootstrapArtifactsDir.appendingPathComponent("cloud-init", isDirectory: true)
        self.bootstrapCloudInitUserDataFile = bootstrapCloudInitDir.appendingPathComponent("user-data", isDirectory: false)
        self.bootstrapCloudInitMetaDataFile = bootstrapCloudInitDir.appendingPathComponent("meta-data", isDirectory: false)
        self.bootstrapCloudInitSeedISOFile = bootstrapArtifactsDir.appendingPathComponent("seed.iso", isDirectory: false)
    }

    public func distroDirectory(named name: String) -> URL {
        distrosDir.appendingPathComponent(name, isDirectory: true)
    }

    public func distroMetadataFile(named name: String) -> URL {
        distroDirectory(named: name).appendingPathComponent("metadata.json", isDirectory: false)
    }

    public func distroDiskFile(named name: String) -> URL {
        distroDirectory(named: name).appendingPathComponent("disk.raw", isDirectory: false)
    }

    public func distroSourceFile(named name: String) -> URL {
        distroDirectory(named: name).appendingPathComponent("source.json", isDirectory: false)
    }

    public func distroTmpDirectory(named name: String) -> URL {
        distroDirectory(named: name).appendingPathComponent("tmp", isDirectory: true)
    }

    public func distroEphemeralTmpDiskFile(named name: String) -> URL {
        distroTmpDirectory(named: name).appendingPathComponent("ephemeral-tmp.raw", isDirectory: false)
    }

    public func bundledContainerToolsDirectory(bundleVersion: String) -> URL {
        mslHostContainerToolsDir.appendingPathComponent(bundleVersion, isDirectory: true)
    }

    public func bundledContainerToolsManifestFile(bundleVersion: String) -> URL {
        bundledContainerToolsDirectory(bundleVersion: bundleVersion)
            .appendingPathComponent("manifest.json", isDirectory: false)
    }

    public func diagnosticLogsDirectory(named instanceName: String) -> URL {
        appLogs
            .appendingPathComponent("instances", isDirectory: true)
            .appendingPathComponent(instanceName, isDirectory: true)
    }

    public func workerContainerDirectory(named instanceName: String) -> URL {
        appControl
            .appendingPathComponent("workers", isDirectory: true)
            .appendingPathComponent(Self.safePathComponent(instanceName), isDirectory: true)
    }

    public func workerRuntimeDirectory(named instanceName: String) -> URL {
        workerContainerDirectory(named: instanceName).appendingPathComponent("runtime", isDirectory: true)
    }

    public func workerControlSocketFile(named instanceName: String) -> URL {
        workerRuntimeDirectory(named: instanceName).appendingPathComponent("control.sock", isDirectory: false)
    }

    public func workerEventSocketFile(named instanceName: String) -> URL {
        workerRuntimeDirectory(named: instanceName).appendingPathComponent("events.sock", isDirectory: false)
    }

    public func sshInstanceDirectory(named instanceName: String) -> URL {
        sshInstancesDir.appendingPathComponent(instanceName, isDirectory: true)
    }

    public func sshInstanceClientPrivateKeyFile(named instanceName: String) -> URL {
        sshInstanceDirectory(named: instanceName).appendingPathComponent("client-ed25519", isDirectory: false)
    }

    public func sshInstanceClientPublicKeyFile(named instanceName: String) -> URL {
        sshInstanceDirectory(named: instanceName).appendingPathComponent("client-ed25519.pub", isDirectory: false)
    }

    public func sshInstanceKnownHostsFile(named instanceName: String) -> URL {
        sshInstanceDirectory(named: instanceName).appendingPathComponent("known_hosts", isDirectory: false)
    }

    public func sshInstanceConfigFile(named instanceName: String) -> URL {
        sshInstanceDirectory(named: instanceName).appendingPathComponent("ssh_config", isDirectory: false)
    }

    public func sshInstanceStateFile(named instanceName: String) -> URL {
        sshInstanceDirectory(named: instanceName).appendingPathComponent("state.json", isDirectory: false)
    }
    private static func safePathComponent(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "default"
        }
        let scalars = trimmed.unicodeScalars.map { scalar -> Character in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 46, 95:
                return Character(scalar)
            default:
                return "_"
            }
        }
        return String(scalars)
    }

    public func instanceLogsDirectory(named instanceName: String) -> URL {
        diagnosticLogsDirectory(named: instanceName)
    }

    public func instanceSessionLogsDirectory(named instanceName: String) -> URL {
        instanceLogsDirectory(named: instanceName).appendingPathComponent("sessions", isDirectory: true)
    }

    public func instanceVMLogsDirectory(named instanceName: String) -> URL {
        instanceLogsDirectory(named: instanceName).appendingPathComponent("vm", isDirectory: true)
    }

    public func sessionLogFile(instanceName: String, sessionID: String) -> URL {
        instanceSessionLogsDirectory(named: instanceName)
            .appendingPathComponent("\(sessionID).log", isDirectory: false)
    }

    public func instanceVMLifecycleLogFile(named instanceName: String) -> URL {
        instanceVMLogsDirectory(named: instanceName)
            .appendingPathComponent("lifecycle.log", isDirectory: false)
    }
}

public func nowEpochMs() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
}
