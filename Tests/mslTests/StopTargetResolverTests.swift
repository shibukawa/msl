import XCTest
@testable import mslCore

final class StopTargetResolverTests: XCTestCase {
    func testResolvesExplicitInstance() {
        let result = StopTargetResolver.resolve(
            explicitInstance: "ubuntu",
            runningInstances: ["ubuntu", "alpine"],
            callerCwd: "/work",
            launchOrigins: [:]
        )
        XCTAssertEqual(try? result.get(), "ubuntu")
    }

    func testSingleRunningFallback() {
        let result = StopTargetResolver.resolve(
            explicitInstance: nil,
            runningInstances: ["ubuntu"],
            callerCwd: nil,
            launchOrigins: [:]
        )
        XCTAssertEqual(try? result.get(), "ubuntu")
    }

    func testCallerAncestorMatch() {
        let result = StopTargetResolver.resolve(
            explicitInstance: nil,
            runningInstances: ["ubuntu", "alpine"],
            callerCwd: "/workspace/project-a/src",
            launchOrigins: [
                "ubuntu": "/workspace/project-a",
                "alpine": "/workspace/project-b"
            ]
        )
        XCTAssertEqual(try? result.get(), "ubuntu")
    }

    func testLongestPrefixWins() {
        let result = StopTargetResolver.resolve(
            explicitInstance: nil,
            runningInstances: ["ubuntu", "alpine"],
            callerCwd: "/workspace/project-a/sub/deep/path",
            launchOrigins: [
                "ubuntu": "/workspace/project-a",
                "alpine": "/workspace/project-a/sub"
            ]
        )
        XCTAssertEqual(try? result.get(), "alpine")
    }

    func testAmbiguousWhenNoCallerMatch() {
        let result = StopTargetResolver.resolve(
            explicitInstance: nil,
            runningInstances: ["ubuntu", "alpine"],
            callerCwd: "/workspace/project-c",
            launchOrigins: [
                "ubuntu": "/workspace/project-a",
                "alpine": "/workspace/project-b"
            ]
        )
        guard case .failure(.ambiguous(let candidates)) = result else {
            return XCTFail("expected ambiguous")
        }
        XCTAssertEqual(candidates, ["alpine", "ubuntu"])
    }
}
