import Foundation
import CryptoKit

public struct StorageImageBuildMetadata: Codable, Equatable {
    public struct HostShare: Codable, Equatable {
        public var host: String
        public var guest: String
        public var readOnly: Bool
    }

    public struct UserPolicy: Codable, Equatable {
        public var name: String
        public var uid: Int
        public var gid: Int
        public var inheritFromMac: Bool
    }

    public struct EnvPolicy: Codable, Equatable {
        public var allow: [String]
        public var hostPrecedence: Bool
    }

    public struct TrimPolicy: Codable, Equatable {
        public var enableTimer: Bool
        public var manualCommand: String
    }

    public var baseImageVersion: String
    public var baseImageSha256: String
    public var profileName: String
    public var compressionPolicy: [CompressionPathPolicyEntry]
    public var hostShares: [HostShare]
    public var caches: [String: Bool]
    public var user: UserPolicy
    public var env: EnvPolicy
    public var trim: TrimPolicy
    public var provisionPlanPath: String
    public var provisionScriptPath: String
    public var createdAt: Int64
    public var toolVersion: String
}

public struct StorageImageProvisionPlan: Codable, Equatable {
    public var imagePath: String
    public var compressionPolicy: [CompressionPathPolicyEntry]
    public var hostShares: [StorageImageBuildMetadata.HostShare]
    public var user: StorageImageBuildMetadata.UserPolicy
    public var env: StorageImageBuildMetadata.EnvPolicy
    public var trim: StorageImageBuildMetadata.TrimPolicy
    public var generatedAtEpochMs: Int64
}

public final class StorageImageBuildManager {
    private let paths: MSLPaths
    private let logger: MSLLogger
    private let fileManager: FileManager

    public init(paths: MSLPaths, logger: MSLLogger, fileManager: FileManager = .default) {
        self.paths = paths
        self.logger = logger
        self.fileManager = fileManager
    }

    public func build(
        profileName: String,
        configPath: String,
        outputPath: String,
        force: Bool
    ) throws -> StorageImageBuildMetadata {
        logger.log("image_build_started", fields: [
            "profile": profileName,
            "config": configPath,
            "output": outputPath
        ])

        let configURL = URL(fileURLWithPath: configPath)
        guard fileManager.fileExists(atPath: configURL.path) else {
            throw MSLRuntimeError("config file not found: \(configURL.path)")
        }
        let raw = try String(contentsOf: configURL, encoding: .utf8)
        let profile = try StorageImageProfileParser.parse(raw, profileName: profileName)

        let catalogStore = CompressionCachePolicyCatalogStore(paths: paths, fileManager: fileManager)
        _ = try catalogStore.ensureDefaultCatalogIfMissing()
        let mergedCompression = try catalogStore.merge(
            basePolicies: profile.compression.pathPolicies,
            cacheToggles: profile.caches
        )

        let baseImageURL = resolveBaseImagePath(profile.image.base)
        guard fileManager.fileExists(atPath: baseImageURL.path) else {
            throw MSLRuntimeError("base image not found: \(baseImageURL.path)")
        }

        let expectedSha = try loadExpectedSha(baseImageURL: baseImageURL)
        let actualSha = try computeSHA256(fileAt: baseImageURL)
        guard expectedSha.caseInsensitiveCompare(actualSha) == .orderedSame else {
            throw MSLRuntimeError("base image hash mismatch: expected \(expectedSha), got \(actualSha)")
        }

        let outputURL = URL(fileURLWithPath: outputPath)
        let outputDir = outputURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: outputURL.path) {
            if !force {
                throw MSLRuntimeError("output already exists: \(outputURL.path) (use --force)")
            }
            try fileManager.removeItem(at: outputURL)
        }

        try fileManager.copyItem(at: baseImageURL, to: outputURL)

        let metadata = StorageImageBuildMetadata(
            baseImageVersion: profile.image.base,
            baseImageSha256: actualSha,
            profileName: profileName,
            compressionPolicy: mergedCompression,
            hostShares: profile.mounts.hostShares.map {
                .init(host: $0.host, guest: $0.guest, readOnly: $0.readOnly)
            },
            caches: profile.caches,
            user: .init(
                name: profile.user.name,
                uid: profile.user.uid,
                gid: profile.user.gid,
                inheritFromMac: profile.user.inheritFromMac
            ),
            env: .init(allow: profile.env.allow, hostPrecedence: profile.env.hostPrecedence),
            trim: .init(enableTimer: profile.trim.enableTimer, manualCommand: profile.trim.manualCommand),
            provisionPlanPath: outputURL.deletingPathExtension().appendingPathExtension("plan.json").path,
            provisionScriptPath: outputURL.deletingPathExtension().appendingPathExtension("provision.sh").path,
            createdAt: nowEpochMs(),
            toolVersion: "step18-v1"
        )

        let metadataURL = outputURL.deletingPathExtension().appendingPathExtension("metadata.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: metadataURL, options: .atomic)

        let plan = StorageImageProvisionPlan(
            imagePath: outputURL.path,
            compressionPolicy: mergedCompression,
            hostShares: metadata.hostShares,
            user: metadata.user,
            env: metadata.env,
            trim: metadata.trim,
            generatedAtEpochMs: nowEpochMs()
        )
        let planData = try encoder.encode(plan)
        let planURL = URL(fileURLWithPath: metadata.provisionPlanPath)
        try planData.write(to: planURL, options: .atomic)

        let script = renderProvisionScript(plan: plan)
        let scriptURL = URL(fileURLWithPath: metadata.provisionScriptPath)
        try script.data(using: .utf8)?.write(to: scriptURL, options: .atomic)
        _ = chmod(scriptURL.path, S_IRWXU | S_IRGRP | S_IROTH)

        let activeScriptURL = paths.storageProvisionScriptFile
        try script.data(using: .utf8)?.write(to: activeScriptURL, options: .atomic)
        _ = chmod(activeScriptURL.path, S_IRWXU | S_IRGRP | S_IROTH)

        logger.log("image_build_completed", fields: [
            "output": outputURL.path,
            "metadata": metadataURL.path,
            "plan": metadata.provisionPlanPath,
            "script": metadata.provisionScriptPath,
            "active_script": activeScriptURL.path,
            "compression_policy_count": String(metadata.compressionPolicy.count)
        ])

        return metadata
    }

    private func renderProvisionScript(plan: StorageImageProvisionPlan) -> String {
        var lines: [String] = []
        lines.append("#!/bin/sh")
        lines.append("set -eu")
        lines.append("LOG=/var/log/msl-storage-provision.log")
        lines.append("TS=\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"")
        lines.append("echo \"${TS} storage_provision_start\" >> \"${LOG}\"")
        lines.append("")

        lines.append("# compression path policies")
        lines.append("if command -v btrfs >/dev/null 2>&1; then")
        for p in plan.compressionPolicy {
            let escapedPath = p.path.replacingOccurrences(of: "\"", with: "\\\"")
            let mode = p.mode.replacingOccurrences(of: "\"", with: "\\\"")
            lines.append("  mkdir -p \"\(escapedPath)\"")
            lines.append("  btrfs property set -ts \"\(escapedPath)\" compression \"\(mode)\" >/dev/null 2>&1 || true")
        }
        lines.append("fi")
        lines.append("")

        lines.append("# host share mounts")
        lines.append("grep -Fqx 'macos /mnt/macos virtiofs rw,nofail 0 0' /etc/fstab || echo 'macos /mnt/macos virtiofs rw,nofail 0 0' >> /etc/fstab")
        for share in plan.hostShares {
            let guestPath = share.guest.replacingOccurrences(of: "\"", with: "\\\"")
            let options = share.readOnly ? "ro,nofail" : "rw,nofail"
            let mountLine = "macos \(guestPath) virtiofs \(options) 0 0"
            let escapedLine = mountLine.replacingOccurrences(of: "'", with: "'\\''")
            lines.append("mkdir -p \"\(guestPath)\"")
            lines.append("grep -Fqx '\(escapedLine)' /etc/fstab || echo '\(escapedLine)' >> /etc/fstab")
        }
        lines.append("mount -a || true")
        lines.append("")

        lines.append("# user identity")
        let userName = plan.user.name.replacingOccurrences(of: "\"", with: "\\\"")
        lines.append("if id \"\(userName)\" >/dev/null 2>&1; then")
        lines.append("  usermod -u \(plan.user.uid) \"\(userName)\" >/dev/null 2>&1 || true")
        lines.append("  groupmod -g \(plan.user.gid) \"\(userName)\" >/dev/null 2>&1 || true")
        lines.append("  chown -R \(plan.user.uid):\(plan.user.gid) \"/home/\(userName)\" >/dev/null 2>&1 || true")
        lines.append("fi")
        lines.append("")

        lines.append("# env allowlist")
        lines.append("mkdir -p /etc/profile.d")
        lines.append("cat > /etc/profile.d/msl-env-allowlist.sh <<'EOF'")
        lines.append("# generated by msl storage image provision")
        lines.append("export MSL_ENV_ALLOWLIST=\"\(plan.env.allow.joined(separator: ","))\"")
        lines.append("export MSL_ENV_HOST_PRECEDENCE=\"\(plan.env.hostPrecedence ? "true" : "false")\"")
        lines.append("EOF")
        lines.append("chmod 0644 /etc/profile.d/msl-env-allowlist.sh")
        lines.append("")

        lines.append("# trim policy")
        if plan.trim.enableTimer {
            lines.append("systemctl enable --now fstrim.timer >/dev/null 2>&1 || true")
        }
        let manual = plan.trim.manualCommand.replacingOccurrences(of: "\"", with: "\\\"")
        lines.append("echo '\(manual)' > /usr/local/sbin/msl-fstrim-manual.sh")
        lines.append("chmod 0755 /usr/local/sbin/msl-fstrim-manual.sh")
        lines.append("")
        lines.append("TS=\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"")
        lines.append("echo \"${TS} storage_provision_done\" >> \"${LOG}\"")

        return lines.joined(separator: "\n") + "\n"
    }

    private func resolveBaseImagePath(_ base: String) -> URL {
        if base.contains("/") {
            return URL(fileURLWithPath: base)
        }
        return paths.imagesDir.appendingPathComponent("\(base).raw", isDirectory: false)
    }

    private func loadExpectedSha(baseImageURL: URL) throws -> String {
        let shaFile = URL(fileURLWithPath: baseImageURL.path + ".sha256")
        guard fileManager.fileExists(atPath: shaFile.path) else {
            throw MSLRuntimeError("missing sha256 file for base image: \(shaFile.path)")
        }
        let content = try String(contentsOf: shaFile, encoding: .utf8)
        let token = content.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).first
        guard let token, !token.isEmpty else {
            throw MSLRuntimeError("invalid sha256 file: \(shaFile.path)")
        }
        return String(token)
    }

    private func computeSHA256(fileAt url: URL) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw MSLRuntimeError("unable to read file: \(url.path)")
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty {
                break
            }
            hasher.update(data: data)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
