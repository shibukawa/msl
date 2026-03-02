import XCTest
@testable import mslCore

final class CacheSharingPolicyTests: XCTestCase {
    func testResolveReturnsDisabledByDefault() {
        let resolved = CacheSharingPolicyResolver.resolve(config: nil)
        XCTAssertFalse(resolved.enabled)
        XCTAssertFalse(resolved.apt)
        XCTAssertFalse(resolved.go)
    }

    func testResolveReturnsAptApkOnlyDefaultsWhenEnabled() {
        let config = CacheSharingConfig(enabled: true)
        let resolved = CacheSharingPolicyResolver.resolve(config: config)
        XCTAssertTrue(resolved.enabled)
        XCTAssertTrue(resolved.apt)
        XCTAssertTrue(resolved.apk)
        XCTAssertFalse(resolved.go)
        XCTAssertFalse(resolved.nuget)
        XCTAssertFalse(resolved.rust)
    }

    func testResolveHonorsPerToolOverrides() {
        let config = CacheSharingConfig(
            enabled: true,
            apt: false,
            npm: false,
            rust: true
        )
        let resolved = CacheSharingPolicyResolver.resolve(config: config)
        XCTAssertFalse(resolved.apt)
        XCTAssertFalse(resolved.npm)
        XCTAssertTrue(resolved.rust)
    }

    func testGuestPathMappingWithRootShare() {
        let guest = CacheSharingPolicyResolver.guestPathForHostPath(
            hostPath: "/Users/alice/Library/Application Support/msl/caches",
            hostShareRoot: "/"
        )
        XCTAssertEqual(guest, "/mnt/macos/Users/alice/Library/Application Support/msl/caches")
    }

    func testGuestPathMappingWithCustomShareRoot() {
        let guest = CacheSharingPolicyResolver.guestPathForHostPath(
            hostPath: "/Users/alice/Library/Application Support/msl/caches",
            hostShareRoot: "/Users/alice"
        )
        XCTAssertEqual(guest, "/mnt/macos/Library/Application Support/msl/caches")
    }

    func testEnvironmentIsEmptyForMountFirstPolicy() {
        let policy = CacheSharingPolicyResolver.resolve(config: .init(
            enabled: true,
            apt: true,
            apk: true,
            go: true,
            python: true,
            npm: true,
            pnpm: true,
            yarn: true,
            maven: true,
            gradle: true,
            composer: true,
            scala: true,
            ruby: true,
            rust: true,
            deno: true,
            bun: true,
            nuget: true
        ))
        let env = CacheSharingPolicyResolver.environment(
            guestCacheRoot: "/mnt/macos/Users/alice/Library/Application Support/msl/caches",
            policy: policy
        )
        XCTAssertTrue(env.isEmpty)
    }

    func testDefaultConfigForDistroFamily() {
        let ubuntu = CacheSharingPolicyResolver.defaultConfigForDistroFamily("ubuntu")
        XCTAssertEqual(ubuntu.enabled, true)
        XCTAssertEqual(ubuntu.apt, true)
        XCTAssertEqual(ubuntu.apk, false)

        let alpine = CacheSharingPolicyResolver.defaultConfigForDistroFamily("alpine")
        XCTAssertEqual(alpine.enabled, true)
        XCTAssertEqual(alpine.apt, false)
        XCTAssertEqual(alpine.apk, true)
    }
}
