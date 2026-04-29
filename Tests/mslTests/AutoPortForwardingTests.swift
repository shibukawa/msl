import XCTest
@testable import mslCore

final class AutoPortForwardingTests: XCTestCase {
    func testDiscoverableHostPortsParsesOnlyListenAndReachableEntries() {
        let sample = """
          sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           0: 00000000:0BB8 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 1 0000000000000000 100 0 0 10 0
           1: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 2 0000000000000000 100 0 0 10 0
           2: 0200A8C0:1388 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 3 0000000000000000 100 0 0 10 0
           3: 0100007F:0016 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 4 0000000000000000 100 0 0 10 0
           4: 00000000:1F40 00000000:0000 01 00000000:00000000 00:00000000 00000000  1000        0 5 0000000000000000 100 0 0 10 0
        """

        let ports = GuestListeningPortDetector.discoverableHostPorts(fromProcNetTCP: sample)
        XCTAssertEqual(ports, Set([3000, 5000]))
    }

    func testDiscoverableHostPortsIgnoresMalformedRows() {
        let sample = """
          sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           xx invalid
           0: 00000000:ZZZZ 00000000:0000 0A
        """

        let ports = GuestListeningPortDetector.discoverableHostPorts(fromProcNetTCP: sample)
        XCTAssertTrue(ports.isEmpty)
    }

    func testMergeKeepsManualMappingWhenHostPortOverlaps() {
        let manual = [
            PortMapping(hostPort: 8080, guestPort: 80),
            PortMapping(hostPort: 9000, guestPort: 9001)
        ]

        let effective = AutoPortForwardingPlanner.merge(
            manualMappings: manual,
            autoHostPorts: Set([8080, 3000]),
            instanceName: "ubuntu"
        )

        XCTAssertEqual(effective.manualHostPorts, Set([8080, 9000]))
        XCTAssertEqual(effective.autoHostPorts, Set([3000]))
        XCTAssertEqual(effective.mappings.map { $0.hostPort }, [3000, 8080, 9000])
        XCTAssertEqual(effective.mappings.first(where: { $0.hostPort == 3000 })?.instance, "ubuntu")
        XCTAssertEqual(effective.mappings.first(where: { $0.hostPort == 8080 })?.guestPort, 80)
    }

    func testNerdctlRunPublishMappingsForwardHostPortToGuestPublishedPort() {
        let mappings = NerdctlPortPublishing.directForwardMappings(
            from: ["run", "-p", "8080:80", "--publish=127.0.0.1:9090:90/tcp", "-p3000:3000", "nginx"],
            instanceName: "_container"
        )

        XCTAssertEqual(mappings.map(\.hostPort), [8080, 9090, 3000])
        XCTAssertEqual(mappings.map(\.guestPort), [8080, 9090, 3000])
        XCTAssertEqual(mappings.map(\.bindAddress), ["127.0.0.1", "127.0.0.1", "127.0.0.1"])
        XCTAssertEqual(mappings.map(\.instance), ["_container", "_container", "_container"])
        XCTAssertEqual(mappings.map(\.source), ["nerdctl", "nerdctl", "nerdctl"])
    }

    func testNerdctlPublishMappingsIgnoreUnsupportedSpecsAndNonRunCommands() {
        let unsupported = NerdctlPortPublishing.directForwardMappings(
            from: ["run", "-p", "80", "-p", "127.0.0.1::80", "--publish", "bad:80"],
            instanceName: "_container"
        )
        let pull = NerdctlPortPublishing.directForwardMappings(
            from: ["pull", "-p", "8080:80", "nginx"],
            instanceName: "_container"
        )

        XCTAssertTrue(unsupported.isEmpty)
        XCTAssertTrue(pull.isEmpty)
    }

    func testNerdctlPublishMappingsOnlyParseRunOptionsBeforeImage() {
        let mappings = NerdctlPortPublishing.directForwardMappings(
            from: ["--namespace", "default", "run", "--name", "web", "-p", "8080:80", "nginx", "echo", "-p", "9000:90"],
            instanceName: "_container"
        )

        XCTAssertEqual(mappings.map(\.hostPort), [8080])
        XCTAssertEqual(mappings.map(\.guestPort), [8080])
    }
}
