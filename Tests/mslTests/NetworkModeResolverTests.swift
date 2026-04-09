import XCTest
@testable import mslCore

final class NetworkModeResolverTests: XCTestCase {
    func testConfiguredModeDefaultsToAuto() {
        XCTAssertEqual(NetworkModeResolver.configuredMode(from: nil), .auto)
        XCTAssertEqual(NetworkModeResolver.configuredMode(from: MSLConfig(network: MSLConfig.NetworkConfig())), .auto)
    }

    func testConfiguredModeReadsExplicitValue() {
        let config = MSLConfig(network: MSLConfig.NetworkConfig(mode: "nat"))
        XCTAssertEqual(NetworkModeResolver.configuredMode(from: config), .nat)
    }

    func testResolveAutoFallsBackToNATWhenOSDoesNotSupportVMNet() {
        let resolved = NetworkModeResolver.resolve(
            configured: .auto,
            executablePath: "/tmp/msl",
            osSupportsVMNet: false,
            binaryHasVMNetEntitlement: true
        )
        XCTAssertEqual(resolved.effective, .nat)
        XCTAssertEqual(resolved.configured, .auto)
        XCTAssertEqual(resolved.reason, "vmnet unavailable: requires macOS 26 or later")
    }

    func testResolveAutoFallsBackToNATWhenEntitlementIsMissing() {
        let resolved = NetworkModeResolver.resolve(
            configured: .auto,
            executablePath: "/tmp/msl",
            osSupportsVMNet: true,
            binaryHasVMNetEntitlement: false
        )
        XCTAssertEqual(resolved.effective, .nat)
        XCTAssertEqual(resolved.reason, "vmnet unavailable: binary is not signed with com.apple.vm.networking")
    }

    func testResolveAutoUsesVMNetWhenAvailable() {
        let resolved = NetworkModeResolver.resolve(
            configured: .auto,
            executablePath: "/tmp/msl",
            osSupportsVMNet: true,
            binaryHasVMNetEntitlement: true
        )
        XCTAssertEqual(resolved.effective, .vmnetShared)
        XCTAssertEqual(resolved.reason, "vmnet available")
    }

    func testResolveExplicitModesDoNotAutoFallback() {
        XCTAssertEqual(
            NetworkModeResolver.resolve(configured: .nat, executablePath: "/tmp/msl").effective,
            .nat
        )
        XCTAssertEqual(
            NetworkModeResolver.resolve(configured: .vmnet, executablePath: "/tmp/msl").effective,
            .vmnetShared
        )
    }

    func testShouldFallbackToNATOnlyForAutoAndVMNetErrors() {
        XCTAssertTrue(
            NetworkModeResolver.shouldFallbackToNAT(
                configured: .auto,
                error: MSLRuntimeError("failed to create vmnet network: not_authorized")
            )
        )
        XCTAssertFalse(
            NetworkModeResolver.shouldFallbackToNAT(
                configured: .vmnet,
                error: MSLRuntimeError("failed to create vmnet network: not_authorized")
            )
        )
    }
}
