import XCTest
@testable import mslCore

final class MemoryBalloonPolicyTests: XCTestCase {
    func testDefaultPlanUsesHalfHostCappedAtEightGiB() {
        let plan = RuntimeMemoryPlan.resolve(
            physicalMemoryBytes: UInt64(32) * 1024 * 1024 * 1024,
            environment: [:],
            minimumAllowedBytes: UInt64(64) * 1024 * 1024,
            maximumAllowedBytes: UInt64(16) * 1024 * 1024 * 1024
        )

        XCTAssertEqual(plan.maxBytes, UInt64(8) * 1024 * 1024 * 1024)
        XCTAssertEqual(plan.startupBytes, UInt64(256) * 1024 * 1024)
        XCTAssertEqual(plan.headroomBytes, UInt64(256) * 1024 * 1024)
        XCTAssertEqual(plan.minDeltaBytes, UInt64(64) * 1024 * 1024)
        XCTAssertEqual(plan.pollIntervalSec, 5)
    }

    func testEnvironmentOverridesAreClamped() {
        let plan = RuntimeMemoryPlan.resolve(
            physicalMemoryBytes: UInt64(8) * 1024 * 1024 * 1024,
            environment: [
                "MSL_MEMORY_MB": "1024",
                "MSL_MEMORY_START_MB": "2048",
                "MSL_MEMORY_HEADROOM_MB": "128",
                "MSL_MEMORY_BALLOON_POLL_SEC": "120",
                "MSL_MEMORY_BALLOON_MIN_DELTA_MB": "32"
            ],
            minimumAllowedBytes: UInt64(64) * 1024 * 1024,
            maximumAllowedBytes: UInt64(4) * 1024 * 1024 * 1024
        )

        XCTAssertEqual(plan.maxBytes, UInt64(1024) * 1024 * 1024)
        XCTAssertEqual(plan.startupBytes, UInt64(1024) * 1024 * 1024)
        XCTAssertEqual(plan.headroomBytes, UInt64(128) * 1024 * 1024)
        XCTAssertEqual(plan.minDeltaBytes, UInt64(32) * 1024 * 1024)
        XCTAssertEqual(plan.pollIntervalSec, 60)
    }

    func testMemInfoParser() {
        let meminfo = """
        MemTotal:        1024000 kB
        MemFree:          100000 kB
        MemAvailable:     512000 kB
        Buffers:            1234 kB
        """

        let parsed = LinuxMemInfoSnapshot.parse(meminfo)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.memTotalBytes, UInt64(1_024_000) * 1024)
        XCTAssertEqual(parsed?.memAvailableBytes, UInt64(512_000) * 1024)
    }

    func testDesiredTargetAppliesHysteresis() {
        let plan = RuntimeMemoryPlan.resolve(
            physicalMemoryBytes: UInt64(8) * 1024 * 1024 * 1024,
            environment: [
                "MSL_MEMORY_MB": "2048",
                "MSL_MEMORY_START_MB": "256",
                "MSL_MEMORY_HEADROOM_MB": "256",
                "MSL_MEMORY_BALLOON_MIN_DELTA_MB": "64"
            ],
            minimumAllowedBytes: UInt64(64) * 1024 * 1024,
            maximumAllowedBytes: UInt64(8) * 1024 * 1024 * 1024
        )

        let snapshot = LinuxMemInfoSnapshot(
            memTotalBytes: UInt64(1024) * 1024 * 1024,
            memAvailableBytes: UInt64(512) * 1024 * 1024
        )

        let unchanged = plan.desiredTargetBytes(
            snapshot: snapshot,
            currentTargetBytes: UInt64(750) * 1024 * 1024
        )
        XCTAssertEqual(unchanged, UInt64(2048) * 1024 * 1024)

        let changed = plan.desiredTargetBytes(
            snapshot: snapshot,
            currentTargetBytes: UInt64(600) * 1024 * 1024
        )
        XCTAssertEqual(changed, UInt64(2048) * 1024 * 1024)
    }

    func testDesiredTargetDoesNotShrinkBelowDynamicFloor() {
        let plan = RuntimeMemoryPlan.resolve(
            physicalMemoryBytes: UInt64(16) * 1024 * 1024 * 1024,
            environment: [
                "MSL_MEMORY_MB": "8192",
                "MSL_MEMORY_START_MB": "256",
                "MSL_MEMORY_HEADROOM_MB": "256",
                "MSL_MEMORY_BALLOON_MIN_DELTA_MB": "64"
            ],
            minimumAllowedBytes: UInt64(64) * 1024 * 1024,
            maximumAllowedBytes: UInt64(16) * 1024 * 1024 * 1024
        )

        let mostlyIdle = LinuxMemInfoSnapshot(
            memTotalBytes: UInt64(8) * 1024 * 1024 * 1024,
            memAvailableBytes: UInt64(7_500) * 1024 * 1024
        )

        XCTAssertEqual(
            plan.desiredTargetBytes(
                snapshot: mostlyIdle,
                currentTargetBytes: UInt64(8) * 1024 * 1024 * 1024
            ),
            UInt64(2048) * 1024 * 1024
        )
    }
}
