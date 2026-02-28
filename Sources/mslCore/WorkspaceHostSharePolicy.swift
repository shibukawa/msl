import Foundation

struct WorkspaceHostSharePolicy {
    static func defaultRoot(fileManager: FileManager = .default) -> String {
        normalizeAbsolutePath(fileManager.homeDirectoryForCurrentUser.path, fileManager: fileManager)
            ?? fileManager.homeDirectoryForCurrentUser.path
    }

    static func resolveRoot(
        config: MSLConfig?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String {
        if let env = environment["MSL_HOST_SHARE_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty,
           let normalized = normalizeAbsolutePath(env, fileManager: fileManager) {
            return normalized
        }
        if let configured = config?.workspaceHostShareRoot?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty,
           let normalized = normalizeAbsolutePath(configured, fileManager: fileManager) {
            return normalized
        }
        return defaultRoot(fileManager: fileManager)
    }

    static func isPathAllowed(_ path: String, withinRoot root: String) -> Bool {
        let normalizedPath = normalizeAbsolutePath(path, fileManager: .default) ?? path
        let normalizedRoot = normalizeAbsolutePath(root, fileManager: .default) ?? root
        if normalizedRoot == "/" {
            return normalizedPath.hasPrefix("/")
        }
        return normalizedPath == normalizedRoot || normalizedPath.hasPrefix(normalizedRoot + "/")
    }

    static func normalizeAbsolutePath(_ raw: String, fileManager: FileManager = .default) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("/") else {
            return nil
        }
        let url = URL(fileURLWithPath: trimmed, isDirectory: true).resolvingSymlinksInPath()
        var normalized = url.path
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        if fileManager.fileExists(atPath: normalized) {
            return normalized
        }
        return normalized
    }
}
