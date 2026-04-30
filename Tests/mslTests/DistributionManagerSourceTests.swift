import XCTest

final class DistributionManagerSourceTests: XCTestCase {
    func testContainerRuntimeRootFSInstallsContainerToolWrappers() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/mslCore/DistributionManager.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("resolveBundledContainerToolArtifact(named: \"buildctl\", platform: \"linux-arm64\")"))
        XCTAssertTrue(source.contains("\"/usr/local/bin/buildctl-real\""))
        XCTAssertTrue(source.contains("name: \"buildctl\""))
        XCTAssertTrue(source.contains("name: \"iptables\""))
        XCTAssertTrue(source.contains("name: \"ip6tables\""))
        XCTAssertTrue(source.contains("name: \"iptables-save\""))
        XCTAssertTrue(source.contains("name: \"iptables-restore\""))
        XCTAssertTrue(source.contains("name: \"ip6tables-save\""))
        XCTAssertTrue(source.contains("name: \"ip6tables-restore\""))
        XCTAssertTrue(source.contains("[dns]"))
        XCTAssertTrue(source.contains("8.8.8.8"))
        XCTAssertTrue(source.contains("2001:4860:4860::8888"))
        XCTAssertTrue(source.contains("etc/nerdctl"))
        XCTAssertTrue(source.contains("etc/nerdctl/nerdctl.toml"))
        XCTAssertTrue(source.contains("snapshotter = \"native\""))
        XCTAssertTrue(source.contains("CONTAINERD_SNAPSHOTTER=native"))
        XCTAssertFalse(source.contains("snapshotter = \"overlayfs\""))
    }
}
