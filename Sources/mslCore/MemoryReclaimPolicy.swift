import Foundation

enum MemoryReclaimStrategy: String {
    case compact
    case dropCaches = "drop_caches"
    case none

    static func parse(_ raw: String?) -> MemoryReclaimStrategy? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return nil
        }
        switch raw {
        case "compact", "compat":
            return .compact
        case "drop_caches", "drop-cache", "dropcache":
            return .dropCaches
        case "none":
            return MemoryReclaimStrategy.none
        default:
            return nil
        }
    }

    var shellCommand: String? {
        switch self {
        case .compact:
            return "echo 1 > /proc/sys/vm/compact_memory"
        case .dropCaches:
            return "sync; echo 1 > /proc/sys/vm/drop_caches"
        case .none:
            return nil
        }
    }
}

enum MemoryReclaimTrigger: String {
    case shortIdle
    case longIdle
    case hostPressure
    case cacheCap
    case manual
}

struct ResolvedMemoryReclaimPolicy {
    var shortIdle: MemoryReclaimStrategy
    var longIdle: MemoryReclaimStrategy
    var hostPressure: MemoryReclaimStrategy
    var cacheCleanThresholdMB: UInt64
    var cacheCleanupCooldownMs: Int64
    var cacheCleanupHysteresisPercent: UInt64

    static let defaultPolicy = ResolvedMemoryReclaimPolicy(
        shortIdle: .none,
        longIdle: .none,
        hostPressure: .dropCaches,
        cacheCleanThresholdMB: 128,
        cacheCleanupCooldownMs: 60_000,
        cacheCleanupHysteresisPercent: 25
    )
}

struct MemoryReclaimPolicyResolution {
    var policy: ResolvedMemoryReclaimPolicy
    var warnings: [String]
}

enum MemoryReclaimPolicyResolver {
    static let shortIdleThresholdMs: Int64 = 60_000
    static let longIdleThresholdMs: Int64 = 300_000
    static let periodicPollIntervalSec: Int = 5
    static let hostPressureCooldownMs: Int64 = 30_000
    static let recentGuestActivitySuspendMs: Int64 = 15_000
    static let defaultCacheCleanThresholdMB: UInt64 = 128
    static let defaultCacheCleanupCooldownSec: Int64 = 60
    static let defaultCacheCleanupHysteresisPercent: UInt64 = 25

    static func resolve(config: MemoryPolicyConfig?) -> MemoryReclaimPolicyResolution {
        var warnings: [String] = []

        func resolveValue(_ value: String?, field: String, fallback: MemoryReclaimStrategy) -> MemoryReclaimStrategy {
            guard let value else {
                return fallback
            }
            guard let parsed = MemoryReclaimStrategy.parse(value) else {
                warnings.append("invalid_memory_policy_\(field)=\(value)")
                return fallback
            }
            return parsed
        }

        let resolvedThresholdMB: UInt64
        let thresholdRaw = config?.cacheCleanThresholdMB
        if let raw = thresholdRaw {
            if raw > 0 {
                resolvedThresholdMB = UInt64(raw)
            } else {
                warnings.append("invalid_memory_policy_cacheCleanThresholdMB=\(raw)")
                resolvedThresholdMB = defaultCacheCleanThresholdMB
            }
        } else {
            resolvedThresholdMB = defaultCacheCleanThresholdMB
        }

        let resolvedCooldownMs: Int64
        if let raw = config?.cooldownDurationS {
            if raw > 0 {
                resolvedCooldownMs = Int64(raw) * 1_000
            } else {
                warnings.append("invalid_memory_policy_cooldownDurationS=\(raw)")
                resolvedCooldownMs = defaultCacheCleanupCooldownSec * 1_000
            }
        } else {
            resolvedCooldownMs = defaultCacheCleanupCooldownSec * 1_000
        }

        let resolvedHysteresisPercent: UInt64
        if let raw = config?.hysteresisPercent {
            if (0...90).contains(raw) {
                resolvedHysteresisPercent = UInt64(raw)
            } else {
                warnings.append("invalid_memory_policy_hysteresisPercent=\(raw)")
                resolvedHysteresisPercent = defaultCacheCleanupHysteresisPercent
            }
        } else {
            resolvedHysteresisPercent = defaultCacheCleanupHysteresisPercent
        }

        let resolved = ResolvedMemoryReclaimPolicy(
            shortIdle: resolveValue(config?.shortIdle, field: "shortIdle", fallback: .none),
            longIdle: resolveValue(config?.longIdle, field: "longIdle", fallback: .none),
            hostPressure: resolveValue(config?.hostPressure, field: "hostPressure", fallback: .dropCaches),
            cacheCleanThresholdMB: resolvedThresholdMB,
            cacheCleanupCooldownMs: resolvedCooldownMs,
            cacheCleanupHysteresisPercent: resolvedHysteresisPercent
        )
        return MemoryReclaimPolicyResolution(policy: resolved, warnings: warnings)
    }

    static func parseLoadAverage1(_ loadavg: String) -> Double? {
        let first = loadavg.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .first
        guard let token = first else {
            return nil
        }
        return Double(token)
    }

    static func shouldTriggerShortIdle(
        nowMs: Int64,
        lastGuestActivityEpochMs: Int64,
        lastShortIdleReclaimEpochMs: Int64?,
        isGuestCPUIdle: Bool
    ) -> Bool {
        guard isGuestCPUIdle else {
            return false
        }
        let inactivityMs = nowMs - lastGuestActivityEpochMs
        guard inactivityMs >= shortIdleThresholdMs else {
            return false
        }
        guard let last = lastShortIdleReclaimEpochMs else {
            return true
        }
        return last < lastGuestActivityEpochMs
    }

    static func shouldTriggerLongIdle(
        nowMs: Int64,
        lastGuestActivityEpochMs: Int64,
        lastLongIdleReclaimEpochMs: Int64?
    ) -> Bool {
        let inactivityMs = nowMs - lastGuestActivityEpochMs
        guard inactivityMs >= longIdleThresholdMs else {
            return false
        }
        guard let last = lastLongIdleReclaimEpochMs else {
            return true
        }
        return last < lastGuestActivityEpochMs
    }

    static func shouldTriggerHostPressure(nowMs: Int64, lastHostPressureReclaimEpochMs: Int64?) -> Bool {
        guard let last = lastHostPressureReclaimEpochMs else {
            return true
        }
        return (nowMs - last) >= hostPressureCooldownMs
    }

    static func isCacheOverCap(
        cacheUsageMB: UInt64,
        cacheCleanThresholdMB: UInt64,
        hysteresisPercent: UInt64,
        wasOverCap: Bool
    ) -> Bool {
        if !wasOverCap {
            return cacheUsageMB > cacheCleanThresholdMB
        }
        let effectivePercent = min(hysteresisPercent, 90)
        let releasePercent = UInt64(100) - effectivePercent
        let releaseThreshold = cacheCleanThresholdMB.saturatingMultiply(releasePercent) / 100
        return cacheUsageMB > releaseThreshold
    }

    static func shouldTriggerCacheCap(
        nowMs: Int64,
        lastCacheCapReclaimEpochMs: Int64?,
        isOverCap: Bool,
        isGuestCPUIdle: Bool,
        cooldownMs: Int64
    ) -> Bool {
        guard isOverCap, isGuestCPUIdle else {
            return false
        }
        guard let last = lastCacheCapReclaimEpochMs else {
            return true
        }
        return (nowMs - last) >= cooldownMs
    }

    static func parseCacheUsageKB(_ meminfo: String) -> UInt64? {
        let lines = meminfo.split(separator: "\n")
        var cachedKB: UInt64?
        var sreclaimableKB: UInt64?
        var shmemKB: UInt64?

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Cached:") {
                cachedKB = parseKilobytesField(line)
            } else if line.hasPrefix("SReclaimable:") {
                sreclaimableKB = parseKilobytesField(line)
            } else if line.hasPrefix("Shmem:") {
                shmemKB = parseKilobytesField(line)
            }
        }
        guard let cached = cachedKB, let reclaimable = sreclaimableKB, let shmem = shmemKB else {
            return nil
        }
        let withReclaimable = cached.addingReportingOverflow(reclaimable)
        if withReclaimable.overflow {
            return UInt64.max
        }
        return withReclaimable.partialValue >= shmem
            ? (withReclaimable.partialValue - shmem)
            : 0
    }

    private static func parseKilobytesField(_ line: String) -> UInt64? {
        let tokens = line.split(separator: " ")
        guard tokens.count >= 2 else {
            return nil
        }
        return UInt64(tokens[1])
    }

    static func shouldSuspendBackgroundMaintenance(
        activeSessionCount: Int,
        nowMs: Int64,
        lastGuestActivityEpochMs: Int64
    ) -> Bool {
        if activeSessionCount > 0 {
            return true
        }
        return (nowMs - lastGuestActivityEpochMs) < recentGuestActivitySuspendMs
    }
}

private extension UInt64 {
    func saturatingMultiply(_ rhs: UInt64) -> UInt64 {
        let mul = self.multipliedReportingOverflow(by: rhs)
        return mul.overflow ? UInt64.max : mul.partialValue
    }
}
