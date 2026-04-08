import XCTest
@testable import mslCore

final class DaemonServerBootstrapScriptTests: XCTestCase {
    func testGuestTransportReadyScriptUsesUniqueTempFile() {
        XCTAssertTrue(DaemonServer.guestTransportReadyScript.contains("mktemp /tmp/msl-udhcpc-script.XXXXXX"))
        XCTAssertTrue(DaemonServer.guestTransportReadyScript.contains("trap 'rm -f \"$UDHCP_SCRIPT\"' EXIT"))
    }

    func testVSCodeServerDirectoriesCommandIncludesRuntimeHomePaths() {
        let command = DaemonServer.makeVSCodeServerDirectoriesCommand(home: "/home/alice")
        XCTAssertTrue(command.contains("/home/alice/.vscode-server/extensionsCache"))
        XCTAssertTrue(command.contains("/home/alice/.vscode-server/data/Machine"))
        XCTAssertTrue(command.contains("defaults,nodiscard"))
        XCTAssertTrue(command.contains("mount -o remount,nodiscard /"))
        XCTAssertTrue(command.contains("! cat \"$dir/product.json\""))
    }

    func testVSCodeRuntimeStateDirectoriesCommandKeepsVarDevcontainerRootOwned() {
        let command = DaemonServer.makeVSCodeRuntimeStateDirectoriesCommand()
        XCTAssertTrue(command.contains("mkdir -p /var/devcontainer"))
        XCTAssertFalse(command.contains(".vscode-server"))
        XCTAssertFalse(command.contains("chown -R"))
        XCTAssertFalse(command.contains("chmod 0775 /var/devcontainer"))
    }

    func testVSCodeRootStateMarkerCreateCommandMatchesVendorPattern() {
        let command = DaemonServer.makeVSCodeRootStateMarkerCreateCommand(
            location: "/var/devcontainer/.patchEtcEnvironmentMarker"
        )
        XCTAssertTrue(command.contains("test ! -f '/var/devcontainer/.patchEtcEnvironmentMarker'"))
        XCTAssertTrue(command.contains("set -o noclobber"))
        XCTAssertTrue(command.contains("mkdir -p '/var/devcontainer'"))
        XCTAssertTrue(command.contains("{ > '/var/devcontainer/.patchEtcEnvironmentMarker' ; }"))
    }

    func testVSCodePatchEtcEnvironmentCommandUsesRuntimeEnv() {
        let command = DaemonServer.makeVSCodePatchEtcEnvironmentCommand(env: [
            "USER": "alice",
            "HOME": "/home/alice",
            "SHELL": "/bin/bash",
            "PATH": "/usr/local/bin:/usr/bin:/bin"
        ])
        XCTAssertTrue(command.contains("cat >> /etc/environment <<'etcEnvironmentEOF'"))
        XCTAssertTrue(command.contains("HOME=\"/home/alice\""))
        XCTAssertTrue(command.contains("PATH=\"/usr/local/bin:/usr/bin:/bin\""))
        XCTAssertTrue(command.contains("SHELL=\"/bin/bash\""))
        XCTAssertTrue(command.contains("USER=\"alice\""))
        XCTAssertTrue(command.contains("etcEnvironmentEOF"))
    }

    func testVSCodePatchEtcProfileCommandMatchesVendorSed() {
        let command = DaemonServer.makeVSCodePatchEtcProfileCommand()
        XCTAssertTrue(command.contains("sed -i -E"))
        XCTAssertTrue(command.contains("/etc/profile"))
        XCTAssertTrue(command.contains("PATH"))
    }

    func testCacheSharePrepareScriptSharesAptArchivesOnly() {
        let command = DaemonServer.cacheSharePrepareScript
        XCTAssertTrue(command.contains("ensure_bind_mount \"$archives_src\" \"/var/cache/apt/archives\""))
        XCTAssertFalse(command.contains("/var/lib/apt/lists"))
    }

    func testCacheSharePrepareScriptProbesArchiveWritability() {
        let command = DaemonServer.cacheSharePrepareScript
        XCTAssertTrue(command.contains("ensure_writable_dir \"/var/cache/apt/archives/partial\""))
        XCTAssertTrue(command.contains("unmount_target \"/var/cache/apt/archives\""))
        XCTAssertTrue(command.contains("apt_archives_unwritable"))
        XCTAssertTrue(command.contains("printf \"status=%s\n\" \"$status\""))
        XCTAssertTrue(command.contains("printf \"reason=%s\n\" \"$fallback_reasons\""))
    }
}
