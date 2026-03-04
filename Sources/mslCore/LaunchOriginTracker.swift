import Foundation

public final class LaunchOriginTracker {
    private let lock = NSLock()
    private var origins: [String: String] = [:]

    public init() {}

    public func record(instance: String, callerCwd: String?) {
        guard let callerCwd = callerCwd,
              let canonical = Self.canonicalizePath(callerCwd),
              !canonical.isEmpty else {
            return
        }
        lock.lock()
        origins[instance] = canonical
        lock.unlock()
    }

    public func origin(for instance: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return origins[instance]
    }

    public func snapshot() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return origins
    }

    public static func canonicalizePath(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}
