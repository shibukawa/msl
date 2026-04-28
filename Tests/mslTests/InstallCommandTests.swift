import XCTest
@testable import msl

final class InstallCommandTests: XCTestCase {
    func testInstallParsesContainerEntrypointOverrideAsRemainingArguments() throws {
        let parsed = try InstallCommand.parse([
            "--from-container", "cgr.dev/chainguard/python:latest",
            "--name", "python",
            "--entrypoint", "python", "-i"
        ])

        let invocation = try parsed.options.resolve()
        XCTAssertEqual(invocation.containerImageRef, "cgr.dev/chainguard/python:latest")
        XCTAssertEqual(invocation.containerEntrypointOverride, ["python", "-i"])
    }

    func testInstallRejectsEntrypointOverrideWithoutContainerSource() {
        XCTAssertThrowsError(try InstallCommand.parse([
            "--rootfs", "/tmp/rootfs.tar.gz",
            "--entrypoint", "python"
        ])) { error in
            XCTAssertTrue(String(describing: error).contains("--entrypoint is only valid with --from-container"))
        }
    }

    func testInstallListRejectsContainerArguments() {
        XCTAssertThrowsError(try InstallCommand.parse([
            "--list",
            "--from-container", "docker.io/library/debian:slim"
        ])) { error in
            XCTAssertTrue(String(describing: error).contains("--list does not accept install arguments"))
        }
    }
}
