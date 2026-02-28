import XCTest
@testable import mslCore

final class CompressionCachePolicyCatalogTests: XCTestCase {
    func testEnsureDefaultCatalogCreatesFileUnderAppSupport() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-cache-policy-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = MSLPaths(homeDirectoryURL: root)
        let store = CompressionCachePolicyCatalogStore(paths: paths)

        let created = try store.ensureDefaultCatalogIfMissing()
        XCTAssertTrue(created)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.compressionCachePolicyCatalogFile.path))

        let catalog = try store.loadCatalog()
        XCTAssertEqual(catalog.schema, 1)
        XCTAssertNotNil(catalog.presets["docker"])
        XCTAssertNotNil(catalog.presets["go"])
        XCTAssertNotNil(catalog.presets["apt"])
        XCTAssertNotNil(catalog.presets["apk"])
    }

    func testMergeAddsOnlyEnabledCachePolicies() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-cache-policy-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = MSLPaths(homeDirectoryURL: root)
        let store = CompressionCachePolicyCatalogStore(paths: paths)
        _ = try store.ensureDefaultCatalogIfMissing()

        let base = [
            CompressionPathPolicyEntry(path: "/var/log", mode: "zstd:1")
        ]
        let merged = try store.merge(basePolicies: base, cacheToggles: [
            "apt": true,
            "apk": false
        ])

        XCTAssertTrue(merged.contains { $0.path == "/var/log" && $0.mode == "zstd:1" })
        XCTAssertTrue(merged.contains { $0.path == "/var/cache/apt" && $0.mode == "none" })
        XCTAssertFalse(merged.contains { $0.path == "/var/cache/apk" })
    }

    func testMergeUsesLastWinsForSamePath() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-cache-policy-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = MSLPaths(homeDirectoryURL: root)
        let store = CompressionCachePolicyCatalogStore(paths: paths)
        _ = try store.ensureDefaultCatalogIfMissing()

        let base = [
            CompressionPathPolicyEntry(path: "/var/cache/apt", mode: "zstd:3")
        ]

        let merged = try store.merge(basePolicies: base, cacheToggles: ["apt": true])
        XCTAssertEqual(merged.first(where: { $0.path == "/var/cache/apt" })?.mode, "none")
    }
}
