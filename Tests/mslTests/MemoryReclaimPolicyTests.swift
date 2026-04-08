import XCTest
@testable import mslCore

final class MemoryReclaimPolicyTests: XCTestCase {
    func testResolveUsesDefaultsWhenConfigMissing() {
        let resolved = MemoryReclaimPolicyResolver.resolve(config: nil)
        XCTAssertEqual(resolved.policy.shortIdle, .none)
        XCTAssertEqual(resolved.policy.longIdle, .none)
        XCTAssertEqual(resolved.policy.hostPressure, .dropCaches)
        XCTAssertEqual(resolved.policy.cacheCleanThresholdMB, 128)
        XCTAssertEqual(resolved.policy.cacheCleanupCooldownMs, 60_000)
        XCTAssertEqual(resolved.policy.cacheCleanupHysteresisPercent, 25)
        XCTAssertTrue(resolved.warnings.isEmpty)
    }

    func testResolveFallsBackOnInvalidValues() {
        let config = MemoryPolicyConfig(
            shortIdle: "invalid",
            longIdle: "none",
            hostPressure: "drop-cache",
            cacheCleanThresholdMB: 512,
            cooldownDurationS: 90,
            hysteresisPercent: 20
        )
        let resolved = MemoryReclaimPolicyResolver.resolve(config: config)
        XCTAssertEqual(resolved.policy.shortIdle, .none)
        XCTAssertEqual(resolved.policy.longIdle, .none)
        XCTAssertEqual(resolved.policy.hostPressure, .dropCaches)
        XCTAssertEqual(resolved.policy.cacheCleanThresholdMB, 512)
        XCTAssertEqual(resolved.policy.cacheCleanupCooldownMs, 90_000)
        XCTAssertEqual(resolved.policy.cacheCleanupHysteresisPercent, 20)
        XCTAssertEqual(resolved.warnings, ["invalid_memory_policy_shortIdle=invalid"])
    }

    func testResolveCacheThresholdInvalidFallsBackToDefaults() {
        let config = MemoryPolicyConfig(cacheCleanThresholdMB: 0, cooldownDurationS: 0, hysteresisPercent: 99)
        let resolved = MemoryReclaimPolicyResolver.resolve(config: config)
        XCTAssertEqual(resolved.policy.cacheCleanThresholdMB, 128)
        XCTAssertEqual(resolved.policy.cacheCleanupCooldownMs, 60_000)
        XCTAssertEqual(resolved.policy.cacheCleanupHysteresisPercent, 25)
        XCTAssertEqual(
            resolved.warnings,
            [
                "invalid_memory_policy_cacheCleanThresholdMB=0",
                "invalid_memory_policy_cooldownDurationS=0",
                "invalid_memory_policy_hysteresisPercent=99",
            ]
        )
    }

    func testShortIdleDecisionRequiresIdleCPU() {
        let now: Int64 = 120_000
        XCTAssertFalse(MemoryReclaimPolicyResolver.shouldTriggerShortIdle(
            nowMs: now,
            lastGuestActivityEpochMs: now - 70_000,
            lastShortIdleReclaimEpochMs: nil,
            isGuestCPUIdle: false
        ))
        XCTAssertTrue(MemoryReclaimPolicyResolver.shouldTriggerShortIdle(
            nowMs: now,
            lastGuestActivityEpochMs: now - 70_000,
            lastShortIdleReclaimEpochMs: nil,
            isGuestCPUIdle: true
        ))
        XCTAssertFalse(MemoryReclaimPolicyResolver.shouldTriggerShortIdle(
            nowMs: now,
            lastGuestActivityEpochMs: now - 70_000,
            lastShortIdleReclaimEpochMs: now - 10_000,
            isGuestCPUIdle: true
        ))
    }

    func testLongIdleDecisionUsesFixed300sThreshold() {
        let now: Int64 = 1_000_000
        XCTAssertFalse(MemoryReclaimPolicyResolver.shouldTriggerLongIdle(
            nowMs: now,
            lastGuestActivityEpochMs: now - 299_000,
            lastLongIdleReclaimEpochMs: nil
        ))
        XCTAssertTrue(MemoryReclaimPolicyResolver.shouldTriggerLongIdle(
            nowMs: now,
            lastGuestActivityEpochMs: now - 300_000,
            lastLongIdleReclaimEpochMs: nil
        ))
    }

    func testHostPressureDecisionHasCooldown() {
        let now: Int64 = 500_000
        XCTAssertTrue(MemoryReclaimPolicyResolver.shouldTriggerHostPressure(
            nowMs: now,
            lastHostPressureReclaimEpochMs: nil
        ))
        XCTAssertFalse(MemoryReclaimPolicyResolver.shouldTriggerHostPressure(
            nowMs: now,
            lastHostPressureReclaimEpochMs: now - 10_000
        ))
        XCTAssertTrue(MemoryReclaimPolicyResolver.shouldTriggerHostPressure(
            nowMs: now,
            lastHostPressureReclaimEpochMs: now - 30_000
        ))
    }

    func testCacheOverCapUsesHysteresis() {
        XCTAssertTrue(MemoryReclaimPolicyResolver.isCacheOverCap(
            cacheUsageMB: 1100,
            cacheCleanThresholdMB: 1024,
            hysteresisPercent: 25,
            wasOverCap: false
        ))
        XCTAssertTrue(MemoryReclaimPolicyResolver.isCacheOverCap(
            cacheUsageMB: 900,
            cacheCleanThresholdMB: 1024,
            hysteresisPercent: 25,
            wasOverCap: true
        ))
        XCTAssertFalse(MemoryReclaimPolicyResolver.isCacheOverCap(
            cacheUsageMB: 760,
            cacheCleanThresholdMB: 1024,
            hysteresisPercent: 25,
            wasOverCap: true
        ))
    }

    func testCacheCapTriggerRequiresIdleAndCooldown() {
        let now: Int64 = 900_000
        XCTAssertTrue(MemoryReclaimPolicyResolver.shouldTriggerCacheCap(
            nowMs: now,
            lastCacheCapReclaimEpochMs: nil,
            isOverCap: true,
            isGuestCPUIdle: true,
            cooldownMs: 60_000
        ))
        XCTAssertFalse(MemoryReclaimPolicyResolver.shouldTriggerCacheCap(
            nowMs: now,
            lastCacheCapReclaimEpochMs: now - 10_000,
            isOverCap: true,
            isGuestCPUIdle: true,
            cooldownMs: 60_000
        ))
        XCTAssertFalse(MemoryReclaimPolicyResolver.shouldTriggerCacheCap(
            nowMs: now,
            lastCacheCapReclaimEpochMs: nil,
            isOverCap: true,
            isGuestCPUIdle: false,
            cooldownMs: 60_000
        ))
        XCTAssertTrue(MemoryReclaimPolicyResolver.shouldTriggerCacheCap(
            nowMs: now,
            lastCacheCapReclaimEpochMs: now - 60_000,
            isOverCap: true,
            isGuestCPUIdle: true,
            cooldownMs: 60_000
        ))
    }

    func testParseCacheUsageKBFromMeminfo() {
        let meminfo = """
        MemTotal:        8123540 kB
        Cached:          900000 kB
        Shmem:            50000 kB
        SReclaimable:    120000 kB
        """
        XCTAssertEqual(MemoryReclaimPolicyResolver.parseCacheUsageKB(meminfo), 970_000)
    }

    func testBackgroundMaintenanceSuspendsForActiveSessions() {
        XCTAssertTrue(MemoryReclaimPolicyResolver.shouldSuspendBackgroundMaintenance(
            activeSessionCount: 1,
            nowMs: 100_000,
            lastGuestActivityEpochMs: 0
        ))
    }

    func testBackgroundMaintenanceSuspendsForRecentGuestActivity() {
        XCTAssertTrue(MemoryReclaimPolicyResolver.shouldSuspendBackgroundMaintenance(
            activeSessionCount: 0,
            nowMs: 100_000,
            lastGuestActivityEpochMs: 90_001
        ))
        XCTAssertFalse(MemoryReclaimPolicyResolver.shouldSuspendBackgroundMaintenance(
            activeSessionCount: 0,
            nowMs: 100_000,
            lastGuestActivityEpochMs: 80_000
        ))
    }
}
