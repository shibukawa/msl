import XCTest
@testable import mslCore

final class DNSPolicyTests: XCTestCase {
    func testResolverPrefersInstanceManualMode() throws {
        let resolver = DNSPolicyResolver()
        let instance = DistributionNetworkDNSPolicy(
            mode: "manual",
            resolverBackend: "replace_resolv_conf",
            manualNameservers: ["1.1.1.1", "8.8.8.8"],
            manualSearchDomains: ["corp.example"]
        )
        let global = MSLConfig.NetworkDNSConfig(
            mode: "host",
            manualNameservers: ["9.9.9.9"],
            manualSearchDomains: ["global.example"]
        )

        let policy = try resolver.resolve(
            instancePolicy: instance,
            globalConfig: global,
            hostSnapshot: HostResolverSnapshot(nameservers: ["10.0.0.1"], searchDomains: [], capturedAtEpochMs: 1, hash: "h")
        )
        XCTAssertEqual(policy.mode, .manual)
        XCTAssertEqual(policy.nameservers, ["1.1.1.1", "8.8.8.8"])
        XCTAssertEqual(policy.searchDomains, ["corp.example"])
    }

    func testResolverUnmanagedSkipsNameservers() throws {
        let resolver = DNSPolicyResolver()
        let policy = try resolver.resolve(
            instancePolicy: DistributionNetworkDNSPolicy(mode: "unmanaged"),
            globalConfig: nil,
            hostSnapshot: nil
        )
        XCTAssertEqual(policy.mode, .unmanaged)
        XCTAssertTrue(policy.nameservers.isEmpty)
    }

    func testHostModeRequiresHostNameserver() {
        let resolver = DNSPolicyResolver()
        XCTAssertThrowsError(
            try resolver.resolve(
                instancePolicy: DistributionNetworkDNSPolicy(mode: "host"),
                globalConfig: nil,
                hostSnapshot: HostResolverSnapshot(nameservers: [], searchDomains: [], capturedAtEpochMs: 1, hash: "h")
            )
        )
    }
}
