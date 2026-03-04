import XCTest
@testable import mslCore

final class LaunchOriginTrackerTests: XCTestCase {
    func testRecordAndSnapshot() {
        let tracker = LaunchOriginTracker()
        tracker.record(instance: "ubuntu", callerCwd: "/tmp")
        let origins = tracker.snapshot()
        XCTAssertEqual(origins["ubuntu"], LaunchOriginTracker.canonicalizePath("/tmp"))
    }

    func testRecordOverwritesPreviousValue() {
        let tracker = LaunchOriginTracker()
        tracker.record(instance: "ubuntu", callerCwd: "/tmp")
        tracker.record(instance: "ubuntu", callerCwd: "/")
        XCTAssertEqual(tracker.origin(for: "ubuntu"), "/")
    }
}
