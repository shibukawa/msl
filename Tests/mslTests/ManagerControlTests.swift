import XCTest
@testable import mslCore

final class ManagerControlTests: XCTestCase {
    func testManagerRequestRoundTrip() throws {
        let request = ManagerControlRequest(
            op: "ensure_instance",
            instance: "ubuntu",
            callerCwd: "/tmp/work",
            hostShareRoot: "/Users/test",
            pid: 42,
            runtimeRoot: "/tmp/runtime",
            controlSocketPath: "/tmp/runtime/control.sock",
            eventSocketPath: "/tmp/runtime/events.sock",
            lifecycleState: .running,
            startupStep: 3,
            startupStepName: "boot",
            lastErrorMessage: nil
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ManagerControlRequest.self, from: data)
        XCTAssertEqual(decoded, request)
    }

    func testWorkerRuntimePathsAreScopedPerInstance() {
        let paths = MSLPaths(homeDirectoryURL: URL(fileURLWithPath: "/tmp/msl-test-home", isDirectory: true))
        XCTAssertTrue(paths.workerControlSocketFile(named: "ubuntu").path.hasSuffix("/app/workers/ubuntu/runtime/control.sock"))
        XCTAssertTrue(paths.workerEventSocketFile(named: "ubuntu").path.hasSuffix("/app/workers/ubuntu/runtime/events.sock"))
    }
}
