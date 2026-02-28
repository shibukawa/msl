import XCTest
@testable import mslCore

final class DefaultInstanceStoreTests: XCTestCase {
    func testLoadEmptyConfigReturnsNoDefaultInstance() throws {
        let ctx = try DefaultInstanceContext.make()
        defer { ctx.cleanup() }

        try Data("{}\n".utf8).write(to: ctx.paths.configFile, options: .atomic)

        let store = DefaultInstanceStore(paths: ctx.paths)
        XCTAssertNil(try store.loadDefaultInstanceName())
    }

    func testSetAndLoadDefaultInstanceRoundTrip() throws {
        let ctx = try DefaultInstanceContext.make()
        defer { ctx.cleanup() }

        let store = DefaultInstanceStore(paths: ctx.paths)
        try store.setDefaultInstanceName("ubuntu-dev")

        XCTAssertEqual(try store.loadDefaultInstanceName(), "ubuntu-dev")
        let config = try store.loadConfig()
        XCTAssertEqual(config.schemaVersion, 1)
        XCTAssertEqual(config.defaultInstanceName, "ubuntu-dev")
    }

    func testSetAndLoadDefaultKernelProfileRefRoundTrip() throws {
        let ctx = try DefaultInstanceContext.make()
        defer { ctx.cleanup() }

        let store = DefaultInstanceStore(paths: ctx.paths)
        try store.setDefaultKernelProfileRef("6.12.4-msl1")

        XCTAssertEqual(try store.loadDefaultKernelProfileRef(), "6.12.4-msl1")
        let config = try store.loadConfig()
        XCTAssertEqual(config.defaultKernelProfileRef, "6.12.4-msl1")
    }

    func testLoadConfigDecodesMemoryPolicy() throws {
        let ctx = try DefaultInstanceContext.make()
        defer { ctx.cleanup() }

        let raw = """
        {
          "schemaVersion": 1,
          "memory": {
            "shortIdle": "none",
            "longIdle": "none",
            "hostPressure": "none",
            "cacheCleanThresholdMB": 768,
            "cooldownDurationS": 45,
            "hysteresisPercent": 30
          }
        }
        """
        try Data(raw.utf8).write(to: ctx.paths.configFile, options: .atomic)

        let store = DefaultInstanceStore(paths: ctx.paths)
        let config = try store.loadConfig()
        XCTAssertEqual(config.memory?.shortIdle, "none")
        XCTAssertEqual(config.memory?.longIdle, "none")
        XCTAssertEqual(config.memory?.hostPressure, "none")
        XCTAssertEqual(config.memory?.cacheCleanThresholdMB, 768)
        XCTAssertEqual(config.memory?.cooldownDurationS, 45)
        XCTAssertEqual(config.memory?.hysteresisPercent, 30)
    }

    func testSetAndLoadStorageCacheToggleRoundTrip() throws {
        let ctx = try DefaultInstanceContext.make()
        defer { ctx.cleanup() }

        let store = DefaultInstanceStore(paths: ctx.paths)
        try store.setStorageCacheToggle(name: "apt", enabled: false)
        try store.setStorageCacheToggle(name: "docker", enabled: true)

        let toggles = try store.loadStorageCacheToggles()
        XCTAssertEqual(toggles["apt"], false)
        XCTAssertEqual(toggles["docker"], true)

        let config = try store.loadConfig()
        XCTAssertEqual(config.storageCacheToggles?["apt"], false)
        XCTAssertEqual(config.storageCacheToggles?["docker"], true)
    }

    func testLoadStorageCacheTogglesReturnsDefaultsWhenUnset() throws {
        let ctx = try DefaultInstanceContext.make()
        defer { ctx.cleanup() }

        let store = DefaultInstanceStore(paths: ctx.paths)
        let toggles = try store.loadStorageCacheToggles()

        XCTAssertEqual(toggles["docker"], false)
        XCTAssertEqual(toggles["go"], true)
        XCTAssertEqual(toggles["apt"], true)
        XCTAssertEqual(toggles["apk"], true)
    }

    func testSaveConfigPersistsDNSNetworkSettings() throws {
        let ctx = try DefaultInstanceContext.make()
        defer { ctx.cleanup() }

        let store = DefaultInstanceStore(paths: ctx.paths)
        let config = MSLConfig(
            schemaVersion: 1,
            network: MSLConfig.NetworkConfig(
                dns: MSLConfig.NetworkDNSConfig(
                    mode: "unmanaged",
                    manualNameservers: ["1.1.1.1"],
                    manualSearchDomains: ["corp.example"]
                )
            )
        )

        try store.saveConfig(config)
        let loaded = try store.loadConfig()
        XCTAssertEqual(loaded.network?.dns?.mode, "unmanaged")
        XCTAssertEqual(loaded.network?.dns?.manualNameservers, ["1.1.1.1"])
        XCTAssertEqual(loaded.network?.dns?.manualSearchDomains, ["corp.example"])
    }
}

private struct DefaultInstanceContext {
    let root: URL
    let paths: MSLPaths

    static func make() throws -> DefaultInstanceContext {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-default-instance-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = MSLPaths(homeDirectoryURL: root)
        try FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
        return DefaultInstanceContext(root: root, paths: paths)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
