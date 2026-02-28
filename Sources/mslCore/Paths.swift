import Foundation
import Darwin

public struct MSLPaths {
    public let home: URL
    public let mslHome: URL
    public let mslSystemHome: URL
    public let appSupport: URL
    public let runtime: URL
    public let logs: URL
    public let appLogs: URL
    public let lockFile: URL
    public let stateFile: URL
    public let sessionsFile: URL
    public let portsFile: URL
    public let runtimeControlSocketFile: URL
    public let initChannelSocketFile: URL
    public let initChannelHandoffFile: URL
    public let initChannelAckFile: URL
    public let configFile: URL
    public let imagesDir: URL
    public let distrosDir: URL
    public let cacheDir: URL
    public let compressionCachePolicyCatalogFile: URL
    public let storageProvisionScriptFile: URL
    public let cacheDownloadsDir: URL
    public let cacheStagingDir: URL
    public let kernelsDir: URL
    public let defaultDistroDir: URL
    public let cloudInitDir: URL
    public let cloudInitUserDataFile: URL
    public let cloudInitMetaDataFile: URL
    public let cloudInitSeedISOFile: URL
    public let machineIdentifierFile: URL
    public let efiVariableStoreFile: URL
    public let mslHostToolsDir: URL
    public let mslHostExt4MkfsHelperBinaryFile: URL
    public let mslHostInitBinaryFile: URL
    public let mslHostExt4HelperBinaryFile: URL
    public let mslHostInitBootstrapLogFile: URL
    public let serialConsoleLogFile: URL

    public init(fileManager: FileManager = .default) {
        self.init(homeDirectoryURL: fileManager.homeDirectoryForCurrentUser)
    }

    public init(homeDirectoryURL: URL) {
        self.home = homeDirectoryURL
        self.mslHome = homeDirectoryURL.appendingPathComponent("msl-home", isDirectory: true)
        self.mslSystemHome = homeDirectoryURL.appendingPathComponent(".msl-system", isDirectory: true)
        self.appSupport = homeDirectoryURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("msl", isDirectory: true)
        self.runtime = appSupport.appendingPathComponent("runtime", isDirectory: true)
        self.logs = runtime.appendingPathComponent("logs", isDirectory: true)
        self.appLogs = appSupport.appendingPathComponent("logs", isDirectory: true)
        self.lockFile = runtime.appendingPathComponent("lock", isDirectory: false)
        self.stateFile = runtime.appendingPathComponent("state.json", isDirectory: false)
        self.sessionsFile = runtime.appendingPathComponent("sessions.json", isDirectory: false)
        self.portsFile = runtime.appendingPathComponent("ports.json", isDirectory: false)
        self.runtimeControlSocketFile = runtime.appendingPathComponent("control.sock", isDirectory: false)
        self.mslHostToolsDir = mslSystemHome
        self.mslHostExt4MkfsHelperBinaryFile = mslHostToolsDir.appendingPathComponent("msl-ext4-mkfs", isDirectory: false)
        self.mslHostInitBinaryFile = mslHostToolsDir.appendingPathComponent("msl-init", isDirectory: false)
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
        self.cacheDir = appSupport.appendingPathComponent("cache", isDirectory: true)
        self.compressionCachePolicyCatalogFile = appSupport.appendingPathComponent("compression-cache-policy-catalog.json", isDirectory: false)
        self.storageProvisionScriptFile = appSupport.appendingPathComponent("storage-provision.sh", isDirectory: false)
        self.cacheDownloadsDir = cacheDir.appendingPathComponent("downloads", isDirectory: true)
        self.cacheStagingDir = cacheDir.appendingPathComponent("staging", isDirectory: true)
        self.kernelsDir = appSupport.appendingPathComponent("kernels", isDirectory: true)
        self.defaultDistroDir = distrosDir.appendingPathComponent("default", isDirectory: true)
        self.cloudInitDir = defaultDistroDir.appendingPathComponent("cloud-init", isDirectory: true)
        self.cloudInitUserDataFile = cloudInitDir.appendingPathComponent("user-data", isDirectory: false)
        self.cloudInitMetaDataFile = cloudInitDir.appendingPathComponent("meta-data", isDirectory: false)
        self.cloudInitSeedISOFile = defaultDistroDir.appendingPathComponent("seed.iso", isDirectory: false)
        self.machineIdentifierFile = defaultDistroDir.appendingPathComponent("machine-identifier.bin", isDirectory: false)
        self.efiVariableStoreFile = defaultDistroDir.appendingPathComponent("efi-variable-store", isDirectory: false)
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

    public func distroCloudInitDirectory(named name: String) -> URL {
        distroDirectory(named: name).appendingPathComponent("cloud-init", isDirectory: true)
    }

    public func diagnosticLogsDirectory(named instanceName: String) -> URL {
        appLogs
            .appendingPathComponent("instances", isDirectory: true)
            .appendingPathComponent(instanceName, isDirectory: true)
    }
}

public func nowEpochMs() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
}
