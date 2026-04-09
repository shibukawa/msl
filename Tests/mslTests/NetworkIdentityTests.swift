import XCTest
@testable import mslCore

final class NetworkIdentityTests: XCTestCase {
    func testServiceHostnameUsesNormalizedInstanceLabel() {
        XCTAssertEqual(NetworkIdentity.serviceHostname(for: "Ubuntu_24.04"), "ubuntu-24-04.msl.localhost")
        XCTAssertEqual(NetworkIdentity.serviceHostname(for: "___"), "msl.msl.localhost")
    }

    func testParseGuestAddressProbeOutputExtractsGuestAndGatewayIPv4() {
        let sample = """
        guest_ipv4=192.168.64.8
        host_gateway_ipv4=192.168.64.1
        """

        let info = NetworkIdentity.parseGuestAddressProbeOutput(sample)
        XCTAssertEqual(info.guestIPv4, "192.168.64.8")
        XCTAssertEqual(info.hostGatewayIPv4, "192.168.64.1")
    }

    func testVMNetTopologyUsesSharedSubnet() {
        let topology = NetworkIdentity.vmnetTopology(for: "ubuntu")
        XCTAssertEqual(topology.instanceName, "ubuntu")
        XCTAssertEqual(topology.serviceHostname, "ubuntu.msl.localhost")
        XCTAssertEqual(topology.hostAlias, "host.msl.localhost")
        XCTAssertEqual(topology.subnetIPv4, "10.77.0.0")
        XCTAssertEqual(topology.hostIPv4, "10.77.0.1")
        XCTAssertNotEqual(topology.guestIPv4, "10.77.0.1")
        XCTAssertEqual(topology.subnetMaskIPv4, "255.255.255.0")
    }

    func testVMNetTopologyAvoidsReservedGuestIPv4Collisions() {
        let first = NetworkIdentity.vmnetTopology(for: "ubuntu")
        let second = NetworkIdentity.vmnetTopology(for: "ubuntu-copy", reservedGuestIPv4s: [first.guestIPv4])
        XCTAssertNotEqual(first.guestIPv4, second.guestIPv4)
        XCTAssertNotEqual(first.guestMACAddress, second.guestMACAddress)
    }

    func testRenderGuestHostsFileReplacesExistingManagedHostAliasEntry() {
        let existing = """
        127.0.0.1 localhost
        192.168.64.1 host.msl.localhost # msl-managed alias=host net=vmnet
        127.0.1.1 ubuntu
        """

        let rendered = NetworkIdentity.renderGuestHostsFile(
            existing: existing,
            hostGatewayIPv4: "192.168.64.2"
        )

        XCTAssertTrue(rendered.contains("127.0.0.1 localhost"))
        XCTAssertTrue(rendered.contains("127.0.1.1 ubuntu"))
        XCTAssertTrue(rendered.contains("192.168.64.2 host.msl.localhost # msl-managed alias=host net=vmnet-shared"))
        XCTAssertFalse(rendered.contains("192.168.64.1 host.msl.localhost # msl-managed alias=host net=vmnet-shared"))
    }

    func testReconcileHostHostsFilePreservesUnmanagedLinesAndAddsManagedInstanceLine() {
        let existing = """
        127.0.0.1 localhost
        10.0.0.10 example.internal
        """
        let topology = NetworkIdentity.vmnetTopology(for: "ubuntu")

        let rendered = NetworkIdentity.reconcileHostHostsFile(existing: existing, topologies: [topology])

        XCTAssertTrue(rendered.conflicts.isEmpty)
        XCTAssertTrue(rendered.rendered.contains("127.0.0.1 localhost"))
        XCTAssertTrue(rendered.rendered.contains("10.0.0.10 example.internal"))
        XCTAssertTrue(rendered.rendered.contains("\(topology.guestIPv4) \(topology.serviceHostname) # msl-managed instance=ubuntu net=vmnet-shared"))
    }

    func testReconcileHostHostsFileSkipsManagedWriteWhenUnmanagedConflictExists() {
        let existing = """
        127.0.0.1 localhost
        192.168.1.20 ubuntu.msl.localhost
        """
        let topology = NetworkIdentity.vmnetTopology(for: "ubuntu")

        let rendered = NetworkIdentity.reconcileHostHostsFile(existing: existing, topologies: [topology])

        XCTAssertEqual(rendered.conflicts, ["ubuntu.msl.localhost"])
        XCTAssertFalse(rendered.rendered.contains("# msl-managed instance=ubuntu net=vmnet-shared"))
    }
}
