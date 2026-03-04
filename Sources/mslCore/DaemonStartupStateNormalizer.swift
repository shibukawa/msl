import Foundation

struct DaemonStartupStateNormalizationSummary: Equatable {
    var normalizedInstances: [String]
    var legacyStateReset: Bool
}

enum DaemonStartupStateNormalizer {
    static func normalizeForDaemonStart(
        state: inout RuntimeState,
        nowMs: Int64
    ) -> DaemonStartupStateNormalizationSummary {
        _ = state.normalizeSchemaV2(nowMs: nowMs)

        let legacyStateReset = needsLegacyReset(state)
        if legacyStateReset {
            state.vmState = .stopped
            state.activeSessionCount = 0
            state.idleTimer = IdleTimerState(armed: false, deadlineEpochMs: nil)
            state.runtimeHostPid = nil
            state.runtimeControlSocket = nil
            state.runtimeUser = nil
            state.initChannel = nil
            state.lastTransitionEpochMs = nowMs
        }

        var normalizedInstances: [String] = []
        if var entries = state.instances {
            for index in entries.indices {
                if needsInstanceReset(entries[index]) {
                    var entry = entries[index]
                    entry.vmState = .stopped
                    entry.activeSessionCount = 0
                    entry.idleTimer = IdleTimerState(armed: false, deadlineEpochMs: nil)
                    entry.runtimeHostPid = nil
                    entry.runtimeControlSocket = nil
                    entry.runtimeUser = nil
                    entry.initChannel = nil
                    entry.lastError = nil
                    entry.lastTransitionEpochMs = nowMs
                    entries[index] = entry
                    normalizedInstances.append(entry.instance)
                }
            }
            state.instances = entries
        }

        return DaemonStartupStateNormalizationSummary(
            normalizedInstances: normalizedInstances.sorted(),
            legacyStateReset: legacyStateReset
        )
    }

    private static func needsLegacyReset(_ state: RuntimeState) -> Bool {
        return state.vmState != .stopped
            || state.activeSessionCount != 0
            || state.idleTimer.armed
            || state.idleTimer.deadlineEpochMs != nil
            || state.runtimeHostPid != nil
            || state.runtimeControlSocket != nil
            || state.runtimeUser != nil
            || state.initChannel != nil
    }

    private static func needsInstanceReset(_ state: RuntimeInstanceState) -> Bool {
        return state.vmState != .stopped
            || state.activeSessionCount != 0
            || state.idleTimer.armed
            || state.idleTimer.deadlineEpochMs != nil
            || state.runtimeHostPid != nil
            || state.runtimeControlSocket != nil
            || state.runtimeUser != nil
            || state.initChannel != nil
    }
}
