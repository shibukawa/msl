import XCTest
@testable import mslCore

final class AttachedCodeOpenRequestTests: XCTestCase {
    func testParseAcceptsValidHomePath() {
        let req = AttachedCodeOpenRequest.parse("OPEN:/home/ubuntu/work")
        XCTAssertEqual(req?.targetPath, "/home/ubuntu/work")
    }

    func testParseAcceptsValidWorkspacePath() {
        let req = AttachedCodeOpenRequest.parse("OPEN:/mnt/macos/Users/me/project")
        XCTAssertEqual(req?.targetPath, "/mnt/macos/Users/me/project")
    }

    func testParseRejectsRelativePath() {
        XCTAssertNil(AttachedCodeOpenRequest.parse("OPEN:./project"))
    }

    func testParseRejectsDisallowedPrefix() {
        XCTAssertNil(AttachedCodeOpenRequest.parse("OPEN:/etc"))
    }

    func testParseRejectsMissingPrefix() {
        XCTAssertNil(AttachedCodeOpenRequest.parse("/home/ubuntu/work"))
    }

    func testOpenForwardErrorReasonCodesAreStable() {
        XCTAssertEqual(AttachedOpenForwardError.codeCLINotFound.reasonCode, "code_cli_not_found")
        XCTAssertEqual(AttachedOpenForwardError.codeCommandFailed(exitCode: 1).reasonCode, "code_command_failed")
        XCTAssertEqual(AttachedOpenForwardError.processLaunchFailed("x").reasonCode, "process_launch_failed")
    }

    func testBuildAttachedContainerAuthorityUsesHexEncodedJSON() throws {
        let authority = try buildAttachedContainerAuthorityString(
            vmID: "msl-ubuntu",
            socketPath: "/tmp/msl-attached.sock"
        )
        XCTAssertTrue(authority.hasPrefix("attached-container+"))
        let hex = String(authority.dropFirst("attached-container+".count))
        XCTAssertFalse(hex.isEmpty)

        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            let pair = String(hex[idx..<next])
            guard let value = UInt8(pair, radix: 16) else {
                XCTFail("hex decode failed")
                return
            }
            bytes.append(value)
            idx = next
        }
        let data = Data(bytes)
        let decoded = try JSONDecoder().decode(AttachedContainerRemoteAuthorityConfig.self, from: data)
        XCTAssertEqual(decoded.containerName, "/msl-ubuntu")
        XCTAssertEqual(decoded.settings?["host"], "unix:///tmp/msl-attached.sock")
    }

    func testResolveAttachedOpenInstanceNamePrefersSourceInstance() {
        XCTAssertEqual(
            resolveAttachedOpenInstanceName(
                sourceInstance: "ubuntu",
                currentRuntimeInstanceName: "_imagewriter"
            ),
            "ubuntu"
        )
    }

    func testResolveAttachedOpenInstanceNameFallsBackToCurrentInstance() {
        XCTAssertEqual(
            resolveAttachedOpenInstanceName(
                sourceInstance: nil,
                currentRuntimeInstanceName: "_imagewriter"
            ),
            "_imagewriter"
        )
        XCTAssertEqual(
            resolveAttachedOpenInstanceName(
                sourceInstance: "  ",
                currentRuntimeInstanceName: "ubuntu"
            ),
            "ubuntu"
        )
    }

    func testResolveAttachedOpenLaunchTargetUsesSourceInstanceSocketAndVmID() {
        let target = resolveAttachedOpenLaunchTarget(
            sourceInstance: "ubuntu",
            currentRuntimeInstanceName: "_imagewriter"
        )

        XCTAssertEqual(target.instanceName, "ubuntu")
        XCTAssertEqual(target.vmID, "msl-ubuntu")
        XCTAssertEqual(
            target.socketPath,
            AttachedContainerIdentity.socketPath(forInstance: "ubuntu")
        )
        XCTAssertNotEqual(
            target.socketPath,
            AttachedContainerIdentity.socketPath(forInstance: "_imagewriter")
        )
    }
}
