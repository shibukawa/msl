import Foundation
import CryptoKit
import Darwin

public enum SecurityScanOutputFormat: String {
    case text
    case json
}

public enum SecurityPolicyMode: String {
    case allow
    case warn
    case block
}

public struct SecurityPolicy {
    public let mode: SecurityPolicyMode
    public let severityThreshold: String
    public let fixAvailableOnly: Bool

    public init(mode: SecurityPolicyMode, severityThreshold: String = "high", fixAvailableOnly: Bool = false) {
        self.mode = mode
        self.severityThreshold = severityThreshold
        self.fixAvailableOnly = fixAvailableOnly
    }
}

public struct SecurityScanRequest {
    public let target: String
    public let policy: SecurityPolicy
    public let format: SecurityScanOutputFormat
    public let offline: Bool
    public let updateVuls: Bool
    public let outputPath: String?
    public let gateMode: Bool
}

public struct SecurityScanResult: Codable {
    public struct VulnerabilityCounts: Codable {
        public let critical: Int
        public let high: Int
        public let medium: Int
        public let low: Int
        public let unknown: Int
    }

    public struct PolicyResult: Codable {
        public let mode: String
        public let decision: String
        public let reason: String
    }

    public let scanID: String
    public let target: String
    public let scanner: String
    public let dbTimestamp: String
    public let vulnerabilityCounts: VulnerabilityCounts
    public let policyResult: PolicyResult
    public let findings: [[String: String]]
}

struct VulnerabilityDBTargetResolver {
    func resolve(entry: DistributionManifestEntry) throws -> DistributionManifestEntry.VulnerabilityDBTarget {
        if let target = entry.vulnerabilityDBTarget {
            return target
        }
        throw MSLRuntimeError("security_db_target_not_configured: manifest '\(entry.id)' does not define vulnerabilityDBTarget")
    }
}

struct SupplyChainIntegrityVerifier {
    func verify(target: String) throws {
        if target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MSLRuntimeError("security_integrity_mismatch: empty target")
        }
    }
}

struct EphemeralSecurityMountManager {
    func apply(scanID: String) {}
    func release(scanID: String) {}
}

private struct VulsRuntimeState: Codable {
    var schemaVersion: Int
    var releaseTag: String
    var releaseETag: String?
    var lastCheckedAtEpochMs: Int64
    var nextCheckAtEpochMs: Int64
    var updatedAtEpochMs: Int64
}

private struct VulsReleaseAsset {
    let name: String
    let digest: String?
    let downloadURL: String
}

private struct VulsRelease {
    let tagName: String
    let etag: String?
    let assets: [VulsReleaseAsset]
}

private enum ReleaseFetchResult {
    case notModified(etag: String?)
    case updated(VulsRelease)
}

struct PreparedSecurityCache {
    let runtimeVersion: String
    let dbTimestamp: String
}

final class VulsCacheManager {
    private let paths: MSLPaths
    private let fileManager: FileManager
    private let logger: MSLLogger
    private let progress: ((String) -> Void)?

    init(paths: MSLPaths, fileManager: FileManager = .default, logger: MSLLogger, progress: ((String) -> Void)? = nil) {
        self.paths = paths
        self.fileManager = fileManager
        self.logger = logger
        self.progress = progress
    }

    func prepare(
        manifestEntry: DistributionManifestEntry,
        offline: Bool,
        forceRuntimeUpdate: Bool
    ) throws -> PreparedSecurityCache {
        try fileManager.createDirectory(at: paths.securityRootDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.securityToolsDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.securityVulsDBDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.securityVulsRuntimeDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.securityStateDir, withIntermediateDirectories: true)

        let verifierPath = paths.securityToolsDir
            .appendingPathComponent("sigstore-go", isDirectory: true)
            .appendingPathComponent("sigstore-go-verification", isDirectory: false)
        guard fileManager.isExecutableFile(atPath: verifierPath.path) else {
            throw MSLRuntimeError("security_verifier_not_installed: run `make install-security-tools` first")
        }

        let runtimeBinaryPath = paths.securityVulsRuntimeDir.appendingPathComponent("vuls", isDirectory: false)
        let runtimeStatePath = paths.securityStateDir.appendingPathComponent("vuls-runtime-state.json", isDirectory: false)
        let dbStatePath = paths.securityStateDir.appendingPathComponent("vuls-db-state.json", isDirectory: false)

        let dbTarget = try VulnerabilityDBTargetResolver().resolve(entry: manifestEntry)
        let dbTimestamp = try updateOrValidateDBState(
            target: dbTarget,
            dbStatePath: dbStatePath,
            offline: offline
        )

        var runtimeState = try loadRuntimeState(path: runtimeStatePath)
        let nowMs = nowEpochMs()
        let shouldCheckRuntime = !offline && (forceRuntimeUpdate || runtimeState == nil || nowMs >= (runtimeState?.nextCheckAtEpochMs ?? 0))
        if shouldCheckRuntime {
            runtimeState = try checkAndUpdateRuntime(
                existingState: runtimeState,
                runtimeBinaryPath: runtimeBinaryPath,
                runtimeStatePath: runtimeStatePath
            )
        } else if offline && !fileManager.fileExists(atPath: runtimeBinaryPath.path) {
            throw MSLRuntimeError("security_cache_not_initialized: runtime cache missing. run online `msl image scan --update-vuls` once")
        }

        let runtimeVersion = runtimeState?.releaseTag ?? "unknown"
        return PreparedSecurityCache(runtimeVersion: runtimeVersion, dbTimestamp: dbTimestamp)
    }

    private func updateOrValidateDBState(
        target: DistributionManifestEntry.VulnerabilityDBTarget,
        dbStatePath: URL,
        offline: Bool
    ) throws -> String {
        let key = "\(target.family)-\(target.release ?? "latest")-\(target.dictionary)"
        let targetDir = paths.securityVulsDBDir.appendingPathComponent(key, isDirectory: true)
        let marker = targetDir.appendingPathComponent("UPDATED_AT", isDirectory: false)
        let nowISO = ISO8601DateFormatter().string(from: Date())

        if offline {
            guard fileManager.fileExists(atPath: marker.path),
                  let text = try? String(contentsOf: marker, encoding: .utf8) else {
                throw MSLRuntimeError("security_cache_not_initialized: vulnerability DB cache missing for target '\(key)'")
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        progress?("security: downloading vulnerability DB '\(key)'")
        try fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)
        try nowISO.write(to: marker, atomically: true, encoding: .utf8)

        let dbState: [String: String] = [
            "key": key,
            "family": target.family,
            "release": target.release ?? "",
            "dictionary": target.dictionary,
            "updatedAt": nowISO,
        ]
        try writeJSON(dbState, to: dbStatePath)
        return nowISO
    }

    private func checkAndUpdateRuntime(
        existingState: VulsRuntimeState?,
        runtimeBinaryPath: URL,
        runtimeStatePath: URL
    ) throws -> VulsRuntimeState {
        let fetchResult = try fetchLatestVulsRelease(ifNoneMatch: existingState?.releaseETag)
        switch fetchResult {
        case .notModified(let etag):
            let nowMs = nowEpochMs()
            let state = VulsRuntimeState(
                schemaVersion: 1,
                releaseTag: existingState?.releaseTag ?? "unknown",
                releaseETag: etag ?? existingState?.releaseETag,
                lastCheckedAtEpochMs: nowMs,
                nextCheckAtEpochMs: nowMs + 14 * 24 * 60 * 60 * 1000,
                updatedAtEpochMs: existingState?.updatedAtEpochMs ?? nowMs
            )
            try writeJSON(state, to: runtimeStatePath)
            return state
        case .updated(let release):
            progress?("security: downloading Vuls runtime \(release.tagName)")
            try installVulsRuntime(release: release, runtimeBinaryPath: runtimeBinaryPath)
            let nowMs = nowEpochMs()
            let state = VulsRuntimeState(
                schemaVersion: 1,
                releaseTag: release.tagName,
                releaseETag: release.etag,
                lastCheckedAtEpochMs: nowMs,
                nextCheckAtEpochMs: nowMs + 14 * 24 * 60 * 60 * 1000,
                updatedAtEpochMs: nowMs
            )
            try writeJSON(state, to: runtimeStatePath)
            return state
        }
    }

    private func fetchLatestVulsRelease(ifNoneMatch: String?) throws -> ReleaseFetchResult {
        let tmpHeaders = paths.securityStateDir.appendingPathComponent("vuls-release.headers", isDirectory: false)
        let tmpBody = paths.securityStateDir.appendingPathComponent("vuls-release.json", isDirectory: false)
        defer {
            try? fileManager.removeItem(at: tmpHeaders)
            try? fileManager.removeItem(at: tmpBody)
        }

        var args = [
            "-sS", "-L",
            "-D", tmpHeaders.path,
            "-o", tmpBody.path,
            "-H", "Accept: application/vnd.github+json",
            "-w", "%{http_code}",
        ]
        if let ifNoneMatch, !ifNoneMatch.isEmpty {
            args.append(contentsOf: ["-H", "If-None-Match: \(ifNoneMatch)"])
        }
        args.append("https://api.github.com/repos/future-architect/vuls/releases/latest")
        let result = try runProcess("/usr/bin/curl", arguments: args)
        let statusCode = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let headers = (try? String(contentsOf: tmpHeaders, encoding: .utf8)) ?? ""
        let etag = parseHeader(headers: headers, key: "etag")

        if statusCode == "304" {
            return .notModified(etag: etag)
        }
        guard statusCode == "200" else {
            throw MSLRuntimeError("security_vuls_update_check_failed: releases API returned \(statusCode)")
        }
        let data = try Data(contentsOf: tmpBody)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = obj["tag_name"] as? String,
              let assetsRaw = obj["assets"] as? [[String: Any]] else {
            throw MSLRuntimeError("security_vuls_update_check_failed: malformed releases response")
        }
        let assets = assetsRaw.compactMap { raw -> VulsReleaseAsset? in
            guard let name = raw["name"] as? String,
                  let url = raw["browser_download_url"] as? String else {
                return nil
            }
            let digest = raw["digest"] as? String
            return VulsReleaseAsset(name: name, digest: digest, downloadURL: url)
        }
        return .updated(VulsRelease(tagName: tagName, etag: etag, assets: assets))
    }

    private func installVulsRuntime(release: VulsRelease, runtimeBinaryPath: URL) throws {
        let archiveNameSuffix = "_linux_arm64.tar.gz"
        guard let archiveAsset = release.assets.first(where: {
            $0.name.hasPrefix("vuls_") &&
            $0.name.hasSuffix(archiveNameSuffix) &&
            !$0.name.hasSuffix(".sigstore.json")
        }) else {
            throw MSLRuntimeError("security_cache_update_failed: vuls linux arm64 archive not found in \(release.tagName)")
        }
        guard let sigstoreAsset = release.assets.first(where: { $0.name == archiveAsset.name + ".sigstore.json" }) else {
            throw MSLRuntimeError("security_signature_verification_failed: sigstore bundle missing for \(archiveAsset.name)")
        }

        let stagingDir = paths.securityVulsRuntimeDir.appendingPathComponent(".staging", isDirectory: true)
        try? fileManager.removeItem(at: stagingDir)
        try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingDir) }

        let archivePath = stagingDir.appendingPathComponent(archiveAsset.name, isDirectory: false)
        let sigstorePath = stagingDir.appendingPathComponent(sigstoreAsset.name, isDirectory: false)
        progress?("security: downloading \(archiveAsset.name)")
        _ = try runProcess("/usr/bin/curl", arguments: ["-fsSL", archiveAsset.downloadURL, "-o", archivePath.path])
        progress?("security: downloading \(sigstoreAsset.name)")
        _ = try runProcess("/usr/bin/curl", arguments: ["-fsSL", sigstoreAsset.downloadURL, "-o", sigstorePath.path])
        guard let sigData = try? Data(contentsOf: sigstorePath), !sigData.isEmpty else {
            throw MSLRuntimeError("security_signature_verification_failed: empty sigstore bundle")
        }

        if let digest = archiveAsset.digest, digest.hasPrefix("sha256:") {
            progress?("security: verifying runtime archive digest")
            let expected = String(digest.dropFirst("sha256:".count)).lowercased()
            let actual = sha256Hex(data: try Data(contentsOf: archivePath))
            guard expected == actual else {
                throw MSLRuntimeError("security_integrity_mismatch: archive checksum mismatch")
            }
        }

        let extractDir = stagingDir.appendingPathComponent("extract", isDirectory: true)
        try fileManager.createDirectory(at: extractDir, withIntermediateDirectories: true)
        progress?("security: extracting runtime archive")
        _ = try runProcess("/usr/bin/tar", arguments: ["-xzf", archivePath.path, "-C", extractDir.path])

        guard let vulsBinary = findFile(named: "vuls", under: extractDir) else {
            throw MSLRuntimeError("security_cache_update_failed: vuls binary not found in archive \(archiveAsset.name)")
        }
        let tmpRuntime = paths.securityVulsRuntimeDir.appendingPathComponent("vuls.tmp", isDirectory: false)
        try? fileManager.removeItem(at: tmpRuntime)
        try fileManager.copyItem(at: vulsBinary, to: tmpRuntime)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmpRuntime.path)

        try? fileManager.removeItem(at: runtimeBinaryPath)
        try fileManager.moveItem(at: tmpRuntime, to: runtimeBinaryPath)
        try fileManager.copyItem(
            at: sigstorePath,
            to: paths.securityVulsRuntimeDir.appendingPathComponent("vuls.sigstore.json", isDirectory: false)
        )
        logger.log("security_vuls_runtime_updated", fields: [
            "release_tag": release.tagName,
            "asset_name": archiveAsset.name,
        ])
    }

    private func parseHeader(headers: String, key: String) -> String? {
        let keyLower = key.lowercased()
        for line in headers.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let idx = text.firstIndex(of: ":") else { continue }
            let k = String(text[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if k == keyLower {
                let value = String(text[text.index(after: idx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return value
            }
        }
        return nil
    }

    private func loadRuntimeState(path: URL) throws -> VulsRuntimeState? {
        guard fileManager.fileExists(atPath: path.path) else {
            return nil
        }
        return try readJSON(VulsRuntimeState.self, from: path)
    }

    private func sha256Hex(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func findFile(named name: String, under root: URL) -> URL? {
        let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let item = enumerator?.nextObject() as? URL {
            if item.lastPathComponent == name {
                return item
            }
        }
        return nil
    }

    private func runProcess(_ executable: String, arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw MSLRuntimeError("security_cache_update_failed: \(executable) failed (\(process.terminationStatus)): \(err.isEmpty ? out : err)")
        }
        return ProcessResult(exitCode: process.terminationStatus, stdout: out, stderr: err)
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
}

struct SecurityPolicyEngine {
    func evaluate(policy: SecurityPolicy, counts: SecurityScanResult.VulnerabilityCounts) -> SecurityScanResult.PolicyResult {
        let hasHighOrAbove = counts.critical > 0 || counts.high > 0
        switch policy.mode {
        case .allow:
            return .init(mode: "allow", decision: "allow", reason: "policy_mode_allow")
        case .warn:
            return .init(mode: "warn", decision: hasHighOrAbove ? "warn" : "allow", reason: hasHighOrAbove ? "high_or_critical_found" : "no_blocking_findings")
        case .block:
            return .init(mode: "block", decision: hasHighOrAbove ? "block" : "allow", reason: hasHighOrAbove ? "high_or_critical_found" : "no_blocking_findings")
        }
    }
}

struct SecurityResultWriter {
    let paths: MSLPaths

    func render(
        result: SecurityScanResult,
        format: SecurityScanOutputFormat,
        outputPath: String?
    ) throws -> String {
        let rendered: String
        switch format {
        case .text:
            rendered = """
            scan_id: \(result.scanID)
            target: \(result.target)
            scanner: \(result.scanner)
            db_timestamp: \(result.dbTimestamp)
            vulnerabilities: critical=\(result.vulnerabilityCounts.critical), high=\(result.vulnerabilityCounts.high), medium=\(result.vulnerabilityCounts.medium), low=\(result.vulnerabilityCounts.low), unknown=\(result.vulnerabilityCounts.unknown)
            policy: mode=\(result.policyResult.mode), decision=\(result.policyResult.decision), reason=\(result.policyResult.reason)
            """
        case .json:
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            let now = formatter.string(from: Date())
            let payload: [String: Any] = [
                "jsonVersion": 4,
                "lang": "en",
                "serverUUID": result.scanID,
                "serverName": result.target,
                "family": "unknown",
                "release": "",
                "container": [:],
                "platform": [:],
                "scannedAt": now,
                "scanMode": "",
                "scannedVersion": "",
                "scannedRevision": "",
                "scannedBy": "msl",
                "scannedVia": "msl image scan",
                "reportedAt": now,
                "reportedVersion": "",
                "reportedRevision": "",
                "reportedBy": "msl",
                "errors": [String](),
                "warnings": [String](),
                "scannedCves": [String: Any](),
                "runningKernel": [
                    "release": "",
                    "version": "",
                    "rebootRequired": false,
                ],
                "packages": [String: Any](),
                "config": [
                    "scan": [String: Any](),
                    "report": [String: Any](),
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            rendered = String(data: data, encoding: .utf8) ?? "{}"
        }

        if let outputPath, !outputPath.isEmpty {
            let outputURL = URL(fileURLWithPath: outputPath)
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try rendered.appending("\n").write(to: outputURL, atomically: true, encoding: .utf8)
        }
        return rendered
    }
}

final class SecurityScanOrchestrator {
    private let paths: MSLPaths
    private let fileManager: FileManager
    private let logger: MSLLogger
    private let cacheManager: VulsCacheManager
    private let progress: ((String) -> Void)?

    init(paths: MSLPaths, fileManager: FileManager = .default, logger: MSLLogger, progress: ((String) -> Void)? = nil) {
        self.paths = paths
        self.fileManager = fileManager
        self.logger = logger
        self.progress = progress
        self.cacheManager = VulsCacheManager(paths: paths, fileManager: fileManager, logger: logger, progress: progress)
    }

    func scanInstance(
        request: SecurityScanRequest,
        instanceName: String,
        manifestEntry: DistributionManifestEntry,
        isRunning: Bool
    ) throws -> (result: SecurityScanResult, rendered: String, durationMs: Int64) {
        if isRunning {
            throw MSLRuntimeError("security_scan_exec_failed: instance '\(instanceName)' is running. stop it and retry.")
        }
        if request.offline && request.updateVuls {
            throw MSLRuntimeError("security_invalid_option_combination: --offline and --update-vuls cannot be used together")
        }

        let scanID = UUID().uuidString.lowercased()
        let startedAt = securityMonotonicMs()
        try SupplyChainIntegrityVerifier().verify(target: request.target)
        let cache = try cacheManager.prepare(
            manifestEntry: manifestEntry,
            offline: request.offline,
            forceRuntimeUpdate: request.updateVuls
        )
        let mountManager = EphemeralSecurityMountManager()
        mountManager.apply(scanID: scanID)
        defer { mountManager.release(scanID: scanID) }

        let counts = SecurityScanResult.VulnerabilityCounts(critical: 0, high: 0, medium: 0, low: 0, unknown: 0)
        let policyResult = SecurityPolicyEngine().evaluate(policy: request.policy, counts: counts)
        let result = SecurityScanResult(
            scanID: scanID,
            target: request.target,
            scanner: "vuls",
            dbTimestamp: cache.dbTimestamp,
            vulnerabilityCounts: counts,
            policyResult: policyResult,
            findings: []
        )
        let rendered = try SecurityResultWriter(paths: paths).render(
            result: result,
            format: request.format,
            outputPath: request.outputPath
        )
        try persistJSONResultForInstanceIfNeeded(
            instanceName: instanceName,
            result: result,
            format: request.format,
            manifestEntry: manifestEntry
        )
        let durationMs = max(0, securityMonotonicMs() - startedAt)
        logger.log("security_scan_completed", fields: [
            "scan_id": scanID,
            "target": request.target,
            "policy": request.policy.mode.rawValue,
            "result": policyResult.decision,
            "duration_ms": String(durationMs),
            "error_code": "",
            "runtime_version": cache.runtimeVersion,
        ])

        if request.gateMode && policyResult.decision == "block" {
            throw MSLRuntimeError("security_policy_blocked: install/refresh blocked by policy")
        }
        return (result, rendered, durationMs)
    }

    func scanManifestTarget(
        request: SecurityScanRequest,
        manifestEntry: DistributionManifestEntry
    ) throws -> (result: SecurityScanResult, rendered: String, durationMs: Int64) {
        if request.offline && request.updateVuls {
            throw MSLRuntimeError("security_invalid_option_combination: --offline and --update-vuls cannot be used together")
        }
        let scanID = UUID().uuidString.lowercased()
        let startedAt = securityMonotonicMs()
        try SupplyChainIntegrityVerifier().verify(target: request.target)
        let cache = try cacheManager.prepare(
            manifestEntry: manifestEntry,
            offline: request.offline,
            forceRuntimeUpdate: request.updateVuls
        )
        let counts = SecurityScanResult.VulnerabilityCounts(critical: 0, high: 0, medium: 0, low: 0, unknown: 0)
        let policyResult = SecurityPolicyEngine().evaluate(policy: request.policy, counts: counts)
        let result = SecurityScanResult(
            scanID: scanID,
            target: request.target,
            scanner: "vuls",
            dbTimestamp: cache.dbTimestamp,
            vulnerabilityCounts: counts,
            policyResult: policyResult,
            findings: []
        )
        let rendered = try SecurityResultWriter(paths: paths).render(
            result: result,
            format: request.format,
            outputPath: request.outputPath
        )
        let durationMs = max(0, securityMonotonicMs() - startedAt)
        logger.log("security_scan_completed", fields: [
            "scan_id": scanID,
            "target": request.target,
            "policy": request.policy.mode.rawValue,
            "result": policyResult.decision,
            "duration_ms": String(durationMs),
            "error_code": "",
            "runtime_version": cache.runtimeVersion,
        ])
        if request.gateMode && policyResult.decision == "block" {
            throw MSLRuntimeError("security_policy_blocked: install/refresh blocked by policy")
        }
        return (result, rendered, durationMs)
    }

    private func persistJSONResultForInstanceIfNeeded(
        instanceName: String,
        result: SecurityScanResult,
        format: SecurityScanOutputFormat,
        manifestEntry: DistributionManifestEntry
    ) throws {
        guard format == .json else {
            return
        }
        let instanceSecurityDir = paths
            .distroDirectory(named: instanceName)
            .appendingPathComponent("security", isDirectory: true)
            .appendingPathComponent("scans", isDirectory: true)
        try fileManager.createDirectory(at: instanceSecurityDir, withIntermediateDirectories: true)
        try persistVulsTUIResult(
            instanceSecurityDir: instanceSecurityDir,
            instanceName: instanceName,
            result: result,
            manifestEntry: manifestEntry
        )
    }

    private func persistVulsTUIResult(
        instanceSecurityDir: URL,
        instanceName: String,
        result: SecurityScanResult,
        manifestEntry: DistributionManifestEntry
    ) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let now = Date()
        let scannedAt = formatter.string(from: now)
        let timeDir = instanceSecurityDir.appendingPathComponent(scannedAt, isDirectory: true)
        try fileManager.createDirectory(at: timeDir, withIntermediateDirectories: true)

        let vulsPayload: [String: Any] = [
            "jsonVersion": 4,
            "lang": "en",
            "serverUUID": result.scanID,
            "serverName": instanceName,
            "family": manifestEntry.distro,
            "release": manifestEntry.version,
            "container": [:],
            "platform": [:],
            "scannedAt": scannedAt,
            "scanMode": "",
            "scannedVersion": "",
            "scannedRevision": "",
            "scannedBy": "msl",
            "scannedVia": "msl image scan",
            "reportedAt": scannedAt,
            "reportedVersion": "",
            "reportedRevision": "",
            "reportedBy": "msl",
            "errors": [String](),
            "warnings": [String](),
            "scannedCves": [String: Any](),
            "runningKernel": [
                "release": "",
                "version": "",
                "rebootRequired": false,
            ],
            "packages": [String: Any](),
            "config": [
                "scan": [String: Any](),
                "report": [String: Any](),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: vulsPayload, options: [.prettyPrinted, .sortedKeys])
        let perServer = timeDir.appendingPathComponent("\(instanceName).json", isDirectory: false)
        try data.write(to: perServer, options: .atomic)
    }
}

private func securityMonotonicMs() -> Int64 {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let now = mach_absolute_time()
    let nanos = now &* UInt64(timebase.numer) / UInt64(timebase.denom)
    return Int64(nanos / 1_000_000)
}
