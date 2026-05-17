import Foundation

public final class BootstrapManager {
    private let paths: MSLPaths
    private let fileManager: FileManager
    private let logger: MSLLogger
    private let prebuilds: PrebuildResolver

    public init(paths: MSLPaths, logger: MSLLogger, fileManager: FileManager = .default) {
        self.paths = paths
        self.logger = logger
        self.fileManager = fileManager
        self.prebuilds = PrebuildResolver(paths: paths, fileManager: fileManager)
    }

    public func ensureBootstrapped(context: BootstrapContext) throws {
        logger.log("bootstrap_started", fields: ["context": bootstrapContextName(context)])
        try ensureDir(paths.mslHome)
        try ensureDir(paths.mslHostToolsDir)
        try ensureDir(paths.appSupport)
        try ensureDir(paths.runtime)
        try ensureDir(paths.logs)
        try ensureDir(paths.imagesDir)
        try ensureDir(paths.distrosDir)
        try ensureDir(paths.mslHostWaylandDir)

        if !fileManager.fileExists(atPath: paths.configFile.path) {
            try Data("{}\n".utf8).write(to: paths.configFile, options: .atomic)
        }

        try ensureCompressionCachePolicyCatalog()

        if context == .runtime {
            logger.log("bootstrap_completed", fields: ["context": bootstrapContextName(context)])
            return
        }

        try stageGuestBinaryIfAvailable(
            envVar: "MSL_INIT_BINARY_PATH",
            binaryName: "msl-init",
            destination: paths.mslHostInitBinaryFile,
            logPrefix: "init_binary"
        )
        try stageGuestBinaryIfAvailable(
            envVar: "MSL_INIT_BOOTLOADER_BINARY_PATH",
            binaryName: "msl-init-bootloader",
            destination: paths.mslHostInitBootloaderBinaryFile,
            logPrefix: "init_bootloader_binary"
        )
        try stageGuestBinaryIfAvailable(
            envVar: "MSL_EARLY_INIT_BINARY_PATH",
            binaryName: "msl-early-init",
            destination: paths.mslHostEarlyInitBinaryFile,
            logPrefix: "early_init_binary"
        )
        try stageGuestBinaryIfAvailable(
            envVar: "MSL_WAYLAND_PROXY_BINARY_PATH",
            binaryName: "msl-wayland-proxy",
            destination: paths.mslHostWaylandProxyBinaryFile,
            logPrefix: "wayland_proxy_binary"
        )
        try stageExt4HelpersIfAvailable()

        logger.log("bootstrap_completed", fields: ["context": bootstrapContextName(context)])
    }

    private func bootstrapContextName(_ context: BootstrapContext) -> String {
        switch context {
        case .runtime:
            return "runtime"
        case .install:
            return "install"
        case .build:
            return "build"
        }
    }

    private func ensureCompressionCachePolicyCatalog() throws {
        let store = CompressionCachePolicyCatalogStore(paths: paths, fileManager: fileManager)
        let created = try store.ensureDefaultCatalogIfMissing()
        if created {
            logger.log("compression_cache_policy_catalog_created", fields: [
                "path": store.catalogFile.path
            ])
        }
    }

    private func ensureDir(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func writeIfChanged(_ data: Data, to url: URL) throws -> Bool {
        if fileManager.fileExists(atPath: url.path) {
            let current = try Data(contentsOf: url)
            if current == data {
                return false
            }
        }
        try data.write(to: url, options: .atomic)
        return true
    }

    private func stageGuestBinaryIfAvailable(
        envVar: String,
        binaryName: String,
        destination: URL,
        logPrefix: String
    ) throws {
        guard let source = resolveGuestBinarySourcePath(envVar: envVar, binaryName: binaryName) else {
            logger.log("\(logPrefix)_missing", fields: ["reason": "source_not_found"])
            return
        }
        guard isSupportedGuestBinary(source) else {
            logger.log("\(logPrefix)_missing", fields: [
                "reason": "invalid_guest_elf",
                "path": source.path
            ])
            return
        }
        if fileManager.fileExists(atPath: destination.path) {
            let current = try? Data(contentsOf: destination)
            let src = try? Data(contentsOf: source)
            if current == src {
                logger.log("\(logPrefix)_reused", fields: ["path": destination.path])
                return
            }
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
        _ = try runCommand("/bin/chmod", ["0755", destination.path])
        logger.log("\(logPrefix)_staged", fields: [
            "src": source.path,
            "dst": destination.path
        ])
    }

    private func isSupportedGuestBinary(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), data.count > 20 else {
            return false
        }
        // ELF magic
        guard data[0] == 0x7f, data[1] == 0x45, data[2] == 0x4c, data[3] == 0x46 else {
            return false
        }
        // 64-bit + little endian
        guard data[4] == 0x02, data[5] == 0x01 else {
            return false
        }
        // e_machine (AArch64 = 183 / 0x00b7), little endian at offset 18
        let machine = UInt16(data[18]) | (UInt16(data[19]) << 8)
        return machine == 183
    }

    private func resolveGuestBinarySourcePath(envVar: String, binaryName: String) -> URL? {
        if let bundled = prebuilds.guestBinary(envVar: envVar, name: binaryName) {
            return bundled
        }
        if let explicit = ProcessInfo.processInfo.environment[envVar], !explicit.isEmpty {
            let url = URL(fileURLWithPath: explicit)
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
            return nil
        }

        var roots: [URL] = []
        roots.append(URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true))
        if let arg0 = CommandLine.arguments.first {
            roots.append(URL(fileURLWithPath: arg0, isDirectory: false).deletingLastPathComponent())
        }

        var candidates: [URL] = []
        for root in roots {
            var cursor = root
            for _ in 0..<8 {
                let c = supportDirectory(for: binaryName, under: cursor)
                    .appendingPathComponent("target", isDirectory: true)
                    .appendingPathComponent("aarch64-unknown-linux-musl", isDirectory: true)
                    .appendingPathComponent("release", isDirectory: true)
                    .appendingPathComponent(binaryName, isDirectory: false)
                candidates.append(c)
                let parent = cursor.deletingLastPathComponent()
                if parent.path == cursor.path {
                    break
                }
                cursor = parent
            }
        }

        for candidate in candidates {
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func supportDirectory(for binaryName: String, under root: URL) -> URL {
        if binaryName == "msl-wayland-proxy" {
            return root
                .appendingPathComponent("Support", isDirectory: true)
                .appendingPathComponent("msl-wayland", isDirectory: true)
        }
        return root
            .appendingPathComponent("Support", isDirectory: true)
            .appendingPathComponent("msl-init", isDirectory: true)
    }

    private func stageExt4HelpersIfAvailable() throws {
        try stageHostToolIfAvailable(
            envVar: "MSL_EXT4_MKFS_HELPER_PATH",
            binaryName: "msl-ext4-mkfs",
            supportDirName: "msl-ext4-mkfs",
            destination: paths.mslHostExt4MkfsHelperBinaryFile,
            logPrefix: "ext4_mkfs_helper"
        )
        try stageHostToolIfAvailable(
            envVar: "MSL_EXT4_HELPER_PATH",
            binaryName: "msl-ext4-image",
            supportDirName: "msl-ext4-image",
            destination: paths.mslHostExt4HelperBinaryFile,
            logPrefix: "ext4_helper"
        )
    }

    private func stageHostToolIfAvailable(
        envVar: String,
        binaryName: String,
        supportDirName: String,
        destination: URL,
        logPrefix: String
    ) throws {
        guard let source = resolveHostToolSourcePath(
            envVar: envVar,
            binaryName: binaryName,
            supportDirName: supportDirName
        ) else {
            logger.log("\(logPrefix)_missing", fields: ["reason": "source_not_found"])
            return
        }

        if fileManager.fileExists(atPath: destination.path) {
            let current = try? Data(contentsOf: destination)
            let src = try? Data(contentsOf: source)
            if current == src {
                logger.log("\(logPrefix)_reused", fields: ["path": destination.path])
                return
            }
        }

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
        _ = try runCommand("/bin/chmod", ["0755", destination.path])
        logger.log("\(logPrefix)_staged", fields: [
            "src": source.path,
            "dst": destination.path
        ])
    }

    private func resolveHostToolSourcePath(
        envVar: String,
        binaryName: String,
        supportDirName: String
    ) -> URL? {
        if let bundled = prebuilds.hostTool(envVar: envVar, name: binaryName) {
            return bundled
        }
        if let explicit = ProcessInfo.processInfo.environment[envVar], !explicit.isEmpty {
            let url = URL(fileURLWithPath: explicit)
            if fileManager.fileExists(atPath: url.path), fileManager.isExecutableFile(atPath: url.path) {
                return url
            }
            return nil
        }

        var roots: [URL] = []
        roots.append(URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true))
        if let arg0 = CommandLine.arguments.first {
            let binDir = URL(fileURLWithPath: arg0, isDirectory: false).deletingLastPathComponent()
            roots.append(binDir)
        }

        var candidates: [URL] = []
        for root in roots {
            candidates.append(root.appendingPathComponent(binaryName, isDirectory: false))
            var cursor = root
            for _ in 0..<8 {
                let c = cursor
                    .appendingPathComponent("Support", isDirectory: true)
                    .appendingPathComponent(supportDirName, isDirectory: true)
                    .appendingPathComponent("target", isDirectory: true)
                    .appendingPathComponent("release", isDirectory: true)
                    .appendingPathComponent(binaryName, isDirectory: false)
                candidates.append(c)
                let parent = cursor.deletingLastPathComponent()
                if parent.path == cursor.path {
                    break
                }
                cursor = parent
            }
        }

        for candidate in candidates {
            if fileManager.fileExists(atPath: candidate.path), fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func runCommand(_ executable: String, _ arguments: [String]) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = nil
        process.standardOutput = nil
        process.standardError = nil
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
