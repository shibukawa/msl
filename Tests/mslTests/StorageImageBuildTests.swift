import XCTest
import CryptoKit
@testable import mslCore

final class StorageImageBuildTests: XCTestCase {
    func testProfileParserValidatesCompressionMode() throws {
        let raw = """
        schema = 1

        [image]
        base = "alpine-vf-3.20"
        size_gb = 64

        [compression]
        default = "zstd:3"

        [[compression.pathPolicies]]
        path = "/var/log"
        mode = "gzip:9"
        """

        XCTAssertThrowsError(try StorageImageProfileParser.parse(raw, profileName: "default")) { error in
            XCTAssertTrue(String(describing: error).contains("compression.pathPolicies.mode"))
        }
    }

    func testProfileParserValidatesHostShareGuestPath() throws {
        let raw = """
        schema = 1

        [image]
        base = "alpine-vf-3.20"
        size_gb = 64

        [compression]
        default = "zstd:3"

        [[compression.pathPolicies]]
        path = "/var/log"
        mode = "zstd:1"

        [[mounts.hostShares]]
        host = "~/cache"
        guest = "mnt/cache"
        readOnly = false
        """

        XCTAssertThrowsError(try StorageImageProfileParser.parse(raw, profileName: "default")) { error in
            XCTAssertTrue(String(describing: error).contains("mounts.hostShares.guest"))
        }
    }

    func testProfileParserParsesEnvAllowAndHostPrecedence() throws {
        let raw = """
        schema = 1

        [image]
        base = "alpine-vf-3.20"
        size_gb = 64

        [compression]
        default = "zstd:3"

        [[compression.pathPolicies]]
        path = "/var/log"
        mode = "zstd:1"

        [env]
        allow = ["LANG", "TERM"]
        hostPrecedence = true
        """

        let parsed = try StorageImageProfileParser.parse(raw, profileName: "default")
        XCTAssertEqual(parsed.env.allow, ["LANG", "TERM"])
        XCTAssertEqual(parsed.env.hostPrecedence, true)
    }

    func testBuildFailsWhenBaseImageHashMismatch() throws {
        let ctx = try StorageImageBuildContext.make()
        defer { ctx.cleanup() }

        let baseImage = ctx.paths.imagesDir.appendingPathComponent("alpine-vf-3.20.raw")
        try FileManager.default.createDirectory(at: ctx.paths.imagesDir, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: baseImage)
        try Data("deadbeef  alpine-vf-3.20.raw\n".utf8).write(to: URL(fileURLWithPath: baseImage.path + ".sha256"))

        let config = ctx.root.appendingPathComponent("profile.toml")
        try Data(sampleProfile.utf8).write(to: config)

        let logger = MSLLogger(logFile: ctx.paths.logs.appendingPathComponent("test.log"))
        let manager = StorageImageBuildManager(paths: ctx.paths, logger: logger)

        XCTAssertThrowsError(
            try manager.build(
                profileName: "default",
                configPath: config.path,
                outputPath: ctx.root.appendingPathComponent("out.raw").path,
                force: false
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("hash mismatch"))
        }
    }

    func testBuildSucceedsAndWritesMetadata() throws {
        let ctx = try StorageImageBuildContext.make()
        defer { ctx.cleanup() }

        let baseImage = ctx.paths.imagesDir.appendingPathComponent("alpine-vf-3.20.raw")
        try FileManager.default.createDirectory(at: ctx.paths.imagesDir, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: baseImage)
        let hash = try sha256(baseImage)
        try Data("\(hash)  alpine-vf-3.20.raw\n".utf8).write(to: URL(fileURLWithPath: baseImage.path + ".sha256"))

        let config = ctx.root.appendingPathComponent("profile.toml")
        try Data(sampleProfile.utf8).write(to: config)

        let output = ctx.root.appendingPathComponent("out.raw")
        let logger = MSLLogger(logFile: ctx.paths.logs.appendingPathComponent("test.log"))
        let manager = StorageImageBuildManager(paths: ctx.paths, logger: logger)

        let metadata = try manager.build(
            profileName: "default",
            configPath: config.path,
            outputPath: output.path,
            force: false
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let metadataURL = output.deletingPathExtension().appendingPathExtension("metadata.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataURL.path))
        XCTAssertEqual(metadata.profileName, "default")
        XCTAssertTrue(metadata.compressionPolicy.contains { $0.path == "/var/cache/apt" })
        XCTAssertEqual(metadata.user.name, NSUserName())
        XCTAssertEqual(metadata.trim.enableTimer, true)
        XCTAssertEqual(metadata.env.allow, ["PATH", "LANG", "LC_ALL", "TERM"])

        let planURL = URL(fileURLWithPath: metadata.provisionPlanPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: planURL.path))

        let planData = try Data(contentsOf: planURL)
        let plan = try JSONDecoder().decode(StorageImageProvisionPlan.self, from: planData)
        XCTAssertTrue(plan.compressionPolicy.contains { $0.path == "/var/cache/apt" })
        XCTAssertEqual(plan.trim.manualCommand, "fstrim -av")

        let scriptURL = URL(fileURLWithPath: metadata.provisionScriptPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptURL.path))
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        XCTAssertTrue(script.contains("btrfs property set -ts"))
        XCTAssertTrue(script.contains("fstrim.timer"))
        XCTAssertTrue(script.contains("/etc/profile.d/msl-env-allowlist.sh"))
    }

    private var sampleProfile: String {
        """
        schema = 1

        [image]
        base = "alpine-vf-3.20"
        size_gb = 64

        [compression]
        default = "zstd:3"

        [[compression.pathPolicies]]
        path = "/var/log"
        mode = "zstd:1"

        [caches]
        apt = true
        """
    }

    private func sha256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return data.sha256Hex
    }
}

private struct StorageImageBuildContext {
    let root: URL
    let paths: MSLPaths

    static func make() throws -> StorageImageBuildContext {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-storage-image-build-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = MSLPaths(homeDirectoryURL: root)
        try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        return StorageImageBuildContext(root: root, paths: paths)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private extension Data {
    var sha256Hex: String {
        let digest = SHA256.hash(data: self)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
