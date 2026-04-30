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
        XCTAssertTrue(source.contains("\"duperemove\""))
        XCTAssertTrue(source.contains("usr/local/bin/msl-btrfs-dedupe"))
        XCTAssertTrue(source.contains("blkid -s UUID -o value /dev/vdb"))
        XCTAssertTrue(source.contains("duperemove -r -d -q --hashfile=\"$hash_file\" --io-threads=1 --cpu-threads=1"))
        XCTAssertTrue(source.contains("sleep 900"))
        XCTAssertTrue(source.contains("try ensureRunlevelLink(service: \"msl-btrfs-dedupe\", rootfsDir: rootfsDir)"))
        XCTAssertFalse(source.contains("snapshotter = \"overlayfs\""))
    }

    func testContainerRuntimeInstallsUseReadonlyBaseCowState() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/mslCore/DistributionManager.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("materialized.sourceRecord.sourceType == \"container-runtime\""))
        XCTAssertTrue(source.contains("targetAlias == \"container-runtime\" ? paths.distroBaseDiskFile(named: name) : diskFile"))
        XCTAssertTrue(source.contains("paths.distroBaseDiskFile(named: name)"))
        XCTAssertTrue(source.contains("paths.distroStateDiskFile(named: name)"))
        XCTAssertTrue(source.contains("paths.distroStateTemplateDiskFile(named: name)"))
        XCTAssertTrue(source.contains("outputStateTemplateDiskPath: stateTemplateDiskFile?.path"))
        XCTAssertTrue(source.contains("imageFS: useReadonlyBaseCowState ? \"erofs\" : \"btrfs\""))
        XCTAssertTrue(source.contains("rootMode: useReadonlyBaseCowState ? .readonlyBaseCowState : nil"))
    }

    func testRemoteContainerInstallsRemainSingleDisk() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/mslCore/DistributionManager.swift"), encoding: .utf8)

        XCTAssertFalse(source.contains("let useReadonlyBaseCowState = materialized.sourceRecord.sourceType == \"container-remote\""))
    }

    func testResetWritableStateUsesTemplateCopy() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/mslCore/DistributionManager.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("func resetWritableState(name rawName: String) throws -> URL"))
        XCTAssertTrue(source.contains("paths.distroStateTemplateDiskFile(named: name)"))
        XCTAssertTrue(source.contains("try copySparseFile(from: templateURL, to: stateURL)"))
    }
}
