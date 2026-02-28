import XCTest
@testable import mslCore

final class WorkspaceHostSharePolicyTests: XCTestCase {
    func testResolveRootUsesConfigValueWhenProvided() {
        let root = WorkspaceHostSharePolicy.resolveRoot(
            config: MSLConfig(workspaceHostShareRoot: "/Users/tester"),
            environment: [:]
        )
        XCTAssertEqual(root, "/Users/tester")
    }

    func testResolveRootPrefersEnvironmentOverride() {
        let root = WorkspaceHostSharePolicy.resolveRoot(
            config: MSLConfig(workspaceHostShareRoot: "/Users/tester"),
            environment: ["MSL_HOST_SHARE_ROOT": "/Volumes/work"]
        )
        XCTAssertEqual(root, "/Volumes/work")
    }

    func testPathAllowedWithinRoot() {
        XCTAssertTrue(WorkspaceHostSharePolicy.isPathAllowed(
            "/Users/alice/project",
            withinRoot: "/Users/alice"
        ))
        XCTAssertFalse(WorkspaceHostSharePolicy.isPathAllowed(
            "/Users/bob/project",
            withinRoot: "/Users/alice"
        ))
    }

    func testPathAllowedWhenRootIsSlash() {
        XCTAssertTrue(WorkspaceHostSharePolicy.isPathAllowed(
            "/opt/workspace",
            withinRoot: "/"
        ))
    }
}
