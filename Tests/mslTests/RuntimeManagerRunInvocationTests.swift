import XCTest
@testable import mslCore

final class RuntimeManagerRunInvocationTests: XCTestCase {
    func testResolveRunInvocationUsesShellWhenAvailable() throws {
        let manager = try makeManager()
        let metadata = makeMetadata(
            shellAvailable: true,
            defaultExec: DistributionInstanceMetadata.DefaultExec(
                argv: ["/usr/bin/python3"],
                source: "image-config"
            )
        )

        let resolved = try manager.resolveRunInvocation(argv: [], metadata: metadata)
        XCTAssertEqual(resolved.argv, ["/bin/sh", "-l"])
        XCTAssertNil(resolved.startupNotice)
    }

    func testResolveRunInvocationFallsBackToDefaultExecForShellLessImage() throws {
        let manager = try makeManager()
        let metadata = makeMetadata(
            shellAvailable: false,
            defaultExec: DistributionInstanceMetadata.DefaultExec(
                argv: ["/usr/bin/python3", "-i"],
                workingDir: "/app",
                user: "root",
                env: ["PYTHONUNBUFFERED=1"],
                source: "install-override"
            )
        )

        let resolved = try manager.resolveRunInvocation(argv: [], metadata: metadata)
        XCTAssertEqual(resolved.argv, ["/usr/bin/python3", "-i"])
        XCTAssertEqual(resolved.cwd, "/app")
        XCTAssertEqual(resolved.envAdditions?["PYTHONUNBUFFERED"], "1")
        XCTAssertEqual(resolved.runAsRoot, true)
        XCTAssertEqual(
            resolved.startupNotice,
            "interactive shell is unavailable for this image; starting configured default command instead"
        )
    }

    func testResolveRunInvocationKeepsExplicitCommandForShellLessImage() throws {
        let manager = try makeManager()
        let metadata = makeMetadata(
            shellAvailable: false,
            defaultExec: DistributionInstanceMetadata.DefaultExec(
                argv: ["/usr/bin/python3"],
                source: "image-config"
            )
        )

        let resolved = try manager.resolveRunInvocation(argv: ["python", "--version"], metadata: metadata)
        XCTAssertEqual(resolved.argv, ["python", "--version"])
        XCTAssertNil(resolved.startupNotice)
    }

    func testNerdctlRunDoesNotRequireWorkspace() throws {
        let manager = try makeManager()
        let plan = try manager.resolveNerdctlWorkspacePlan(argv: ["run", "--rm", "alpine", "uname", "-m"])
        XCTAssertFalse(plan.requiresWorkspace)
    }

    func testNerdctlBuildRequiresWorkspace() throws {
        let manager = try makeManager()
        let plan = try manager.resolveNerdctlWorkspacePlan(argv: ["build", "-t", "demo", "."])
        XCTAssertTrue(plan.requiresWorkspace)
    }

    func testNerdctlBuildRequiresWorkspaceWhenUsingGlobalOptionPrefix() throws {
        let manager = try makeManager()
        let plan = try manager.resolveNerdctlWorkspacePlan(argv: ["--namespace", "buildkit", "build", "."])
        XCTAssertTrue(plan.requiresWorkspace)
    }

    func testNerdctlComposeRequiresWorkspace() throws {
        let manager = try makeManager()
        let plan = try manager.resolveNerdctlWorkspacePlan(argv: ["compose", "up"])
        XCTAssertTrue(plan.requiresWorkspace)
    }

    func testNerdctlBuildRejectsContextOutsideCurrentWorkspace() throws {
        let manager = try makeManager()
        XCTAssertThrowsError(try manager.resolveNerdctlWorkspacePlan(argv: ["build", "../other"])) { error in
            XCTAssertTrue(String(describing: error).contains("build context must stay within the current workspace"))
        }
    }

    func testNerdctlComposeRejectsFileOutsideCurrentWorkspace() throws {
        let manager = try makeManager()
        XCTAssertThrowsError(try manager.resolveNerdctlWorkspacePlan(argv: ["compose", "-f", "../docker-compose.yml", "up"])) { error in
            XCTAssertTrue(String(describing: error).contains("compose file must stay within the current workspace"))
        }
    }

    private func makeManager() throws -> RuntimeManager {
        try RuntimeManager(executablePath: "/bin/echo", fileManager: .default)
    }

    private func makeMetadata(
        shellAvailable: Bool?,
        defaultExec: DistributionInstanceMetadata.DefaultExec?
    ) -> DistributionInstanceMetadata {
        DistributionInstanceMetadata(
            name: "python",
            createdAtEpochMs: nowEpochMs(),
            source: DistributionSourceRecord(
                sourceType: "container-remote",
                tarballFileName: "rootfs.oci",
                sha256: "abc",
                verifiedAtEpochMs: nowEpochMs()
            ),
            diskPath: "/tmp/python.raw",
            kernelProfileRef: nil,
            userConvergencePolicy: UserConvergencePolicyTemplate(
                templateId: "test",
                commandFamily: "busybox_adduser",
                adminGroup: "wheel",
                sudoPolicy: SudoPolicyTemplate(),
                shellFallbacks: ["/bin/sh"],
                welcomePolicy: WelcomePolicyTemplate()
            ),
            defaultExec: defaultExec,
            shellAvailable: shellAvailable
        )
    }
}
