import Foundation

struct RuntimeMemoryPlan {
    static let mebibyte: UInt64 = 1024 * 1024
    private static let defaultDynamicFloorBytes: UInt64 = 2 * 1024 * 1024 * 1024

    let maxBytes: UInt64
    let startupBytes: UInt64
    let headroomBytes: UInt64
    let minDeltaBytes: UInt64
    let pollIntervalSec: Int

    static func resolve(
        physicalMemoryBytes: UInt64,
        environment: [String: String],
        minimumAllowedBytes: UInt64,
        maximumAllowedBytes: UInt64
    ) -> RuntimeMemoryPlan {
        let eightGiB = UInt64(8) * 1024 * 1024 * 1024
        let defaultMax = min(physicalMemoryBytes / 2, eightGiB)

        let maxFromEnv = parsePositiveMiB(environment["MSL_MEMORY_MB"])
        let maxCandidate = maxFromEnv ?? defaultMax
        let resolvedMax = clamp(roundDownToMiB(maxCandidate), lower: minimumAllowedBytes, upper: maximumAllowedBytes)

        let startupDefault = UInt64(256) * mebibyte
        let startupFromEnv = parsePositiveMiB(environment["MSL_MEMORY_START_MB"])
        let startupCandidate = startupFromEnv ?? startupDefault
        let resolvedStartup = clamp(roundDownToMiB(startupCandidate), lower: minimumAllowedBytes, upper: resolvedMax)

        let headroomDefault = UInt64(256) * mebibyte
        let headroomFromEnv = parsePositiveMiB(environment["MSL_MEMORY_HEADROOM_MB"])
        let resolvedHeadroom = roundDownToMiB(headroomFromEnv ?? headroomDefault)

        let minDeltaDefault = UInt64(64) * mebibyte
        let minDeltaFromEnv = parsePositiveMiB(environment["MSL_MEMORY_BALLOON_MIN_DELTA_MB"])
        let resolvedMinDelta = roundDownToMiB(minDeltaFromEnv ?? minDeltaDefault)

        let pollInterval = parsePositiveInt(environment["MSL_MEMORY_BALLOON_POLL_SEC"]) ?? 5
        let resolvedPollInterval = max(1, min(pollInterval, 60))

        return RuntimeMemoryPlan(
            maxBytes: resolvedMax,
            startupBytes: resolvedStartup,
            headroomBytes: resolvedHeadroom,
            minDeltaBytes: resolvedMinDelta,
            pollIntervalSec: resolvedPollInterval
        )
    }

    func desiredTargetBytes(snapshot: LinuxMemInfoSnapshot, currentTargetBytes: UInt64) -> UInt64 {
        guard snapshot.memTotalBytes > 0 else {
            return currentTargetBytes
        }

        let boundedAvailable = min(snapshot.memAvailableBytes, snapshot.memTotalBytes)
        let usedBytes = snapshot.memTotalBytes - boundedAvailable
        let withHeadroom = usedBytes.addingReportingOverflow(headroomBytes)
        let requested = withHeadroom.overflow ? UInt64.max : withHeadroom.partialValue

        let rounded = Self.roundUpToMiB(requested)
        let dynamicFloor = min(maxBytes, max(startupBytes, Self.defaultDynamicFloorBytes))
        let clamped = Self.clamp(rounded, lower: dynamicFloor, upper: maxBytes)

        let delta: UInt64
        if clamped > currentTargetBytes {
            delta = clamped - currentTargetBytes
        } else {
            delta = currentTargetBytes - clamped
        }

        if delta < minDeltaBytes {
            return currentTargetBytes
        }
        return clamped
    }

    private static func parsePositiveMiB(_ value: String?) -> UInt64? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let mb = UInt64(raw),
              mb > 0 else {
            return nil
        }
        return mb * mebibyte
    }

    private static func parsePositiveInt(_ value: String?) -> Int? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let n = Int(raw),
              n > 0 else {
            return nil
        }
        return n
    }

    private static func roundDownToMiB(_ value: UInt64) -> UInt64 {
        (value / mebibyte) * mebibyte
    }

    private static func roundUpToMiB(_ value: UInt64) -> UInt64 {
        if value == 0 {
            return 0
        }
        return ((value + mebibyte - 1) / mebibyte) * mebibyte
    }

    private static func clamp(_ value: UInt64, lower: UInt64, upper: UInt64) -> UInt64 {
        min(max(value, lower), upper)
    }
}

struct LinuxMemInfoSnapshot {
    let memTotalBytes: UInt64
    let memAvailableBytes: UInt64

    static func parse(_ text: String) -> LinuxMemInfoSnapshot? {
        let lines = text.split(separator: "\n")
        var totalKB: UInt64?
        var availableKB: UInt64?

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("MemTotal:") {
                totalKB = parseKilobytesValue(line: line)
            } else if line.hasPrefix("MemAvailable:") {
                availableKB = parseKilobytesValue(line: line)
            }
        }

        guard let total = totalKB, let available = availableKB else {
            return nil
        }
        return LinuxMemInfoSnapshot(memTotalBytes: total * 1024, memAvailableBytes: available * 1024)
    }

    private static func parseKilobytesValue(line: String) -> UInt64? {
        let tokens = line.split(separator: " ").map(String.init)
        guard tokens.count >= 2 else {
            return nil
        }
        return UInt64(tokens[1])
    }
}
