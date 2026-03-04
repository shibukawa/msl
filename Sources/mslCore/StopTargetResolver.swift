import Foundation

public enum StopTargetResolutionError: Error, Equatable {
    case noRunningInstances
    case targetNotRunning(instance: String)
    case ambiguous(candidates: [String])
}

public enum StopTargetResolver {
    public static func resolve(
        explicitInstance: String?,
        runningInstances: [String],
        callerCwd: String?,
        launchOrigins: [String: String]
    ) -> Result<String, StopTargetResolutionError> {
        let uniqueRunning = Array(Set(runningInstances)).sorted()
        if let explicit = explicitInstance?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            guard uniqueRunning.contains(explicit) else {
                return .failure(.targetNotRunning(instance: explicit))
            }
            return .success(explicit)
        }

        guard !uniqueRunning.isEmpty else {
            return .failure(.noRunningInstances)
        }
        if uniqueRunning.count == 1, let only = uniqueRunning.first {
            return .success(only)
        }

        guard let caller = callerCwd,
              let canonicalCaller = LaunchOriginTracker.canonicalizePath(caller) else {
            return .failure(.ambiguous(candidates: uniqueRunning))
        }

        var matches: [(instance: String, depth: Int)] = []
        for instance in uniqueRunning {
            guard let origin = launchOrigins[instance],
                  isAncestorPath(origin, of: canonicalCaller) else {
                continue
            }
            matches.append((instance: instance, depth: pathDepth(origin)))
        }

        guard !matches.isEmpty else {
            return .failure(.ambiguous(candidates: uniqueRunning))
        }

        let bestDepth = matches.map(\.depth).max() ?? 0
        let best = matches
            .filter { $0.depth == bestDepth }
            .map(\.instance)
            .sorted()
        if best.count == 1, let selected = best.first {
            return .success(selected)
        }
        return .failure(.ambiguous(candidates: best))
    }

    private static func isAncestorPath(_ ancestor: String, of path: String) -> Bool {
        if ancestor == "/" {
            return path.hasPrefix("/")
        }
        if path == ancestor {
            return true
        }
        return path.hasPrefix(ancestor + "/")
    }

    private static func pathDepth(_ path: String) -> Int {
        if path == "/" { return 0 }
        return path.split(separator: "/").count
    }
}
