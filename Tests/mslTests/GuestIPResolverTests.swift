import XCTest
@testable import mslCore

final class GuestIPResolverTests: XCTestCase {
    func testUpdateGuestIPTakesPriorityOverFallbacks() {
        let resolver = GuestIPResolver(explicitIP: nil)

        resolver.updateGuestIP("192.168.64.6")

        XCTAssertEqual(resolver.candidateIPs().first, "192.168.64.6")
    }

    func testUpdateGuestIPKeepsInitialExplicitIPAsFallback() {
        let resolver = GuestIPResolver(explicitIP: "192.168.64.2")

        resolver.updateGuestIP("192.168.64.6")

        let candidates = resolver.candidateIPs()
        XCTAssertEqual(candidates.first, "192.168.64.6")
        XCTAssertTrue(candidates.contains("192.168.64.2"))
    }

    func testParseArpOutputFiltersPrivateVmnetEntries() {
        let sample = """
        ? (192.168.64.8) at aa:bb:cc:dd:ee:ff on bridge100 ifscope [bridge]
        ? (10.0.0.42) at 11:22:33:44:55:66 on vmnet8 ifscope [ethernet]
        ? (172.16.12.3) at aa:00:00:00:00:01 on vmenet0 ifscope [ethernet]
        ? (8.8.8.8) at aa:aa:aa:aa:aa:aa on bridge100 ifscope [bridge]
        ? (192.168.1.4) at aa:aa:aa:aa:aa:aa on en0 ifscope [ethernet]
        """

        let ips = GuestIPResolver.parseArpOutput(sample)
        XCTAssertEqual(ips, ["192.168.64.8", "10.0.0.42", "172.16.12.3"])
    }
}
