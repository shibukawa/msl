import Foundation

public final class RuntimeLogRouter {
    private let paths: MSLPaths
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(paths: MSLPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public func ensureSessionLogFile(instance: String, sessionID: String) throws -> URL {
        let dir = paths.instanceSessionLogsDirectory(named: instance)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = paths.sessionLogFile(instanceName: instance, sessionID: sessionID)
        if !fileManager.fileExists(atPath: file.path) {
            _ = fileManager.createFile(atPath: file.path, contents: nil)
        }
        return file
    }

    public func logSession(
        instance: String,
        sessionID: String,
        event: String,
        fields: [String: String] = [:]
    ) {
        do {
            let file = try ensureSessionLogFile(instance: instance, sessionID: sessionID)
            try append(fileURL: file, event: event, instance: instance, sessionID: sessionID, fields: fields)
        } catch {
            // best-effort
        }
    }

    public func logVM(instance: String, event: String, fields: [String: String] = [:]) {
        do {
            let dir = paths.instanceVMLogsDirectory(named: instance)
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = paths.instanceVMLifecycleLogFile(named: instance)
            if !fileManager.fileExists(atPath: file.path) {
                _ = fileManager.createFile(atPath: file.path, contents: nil)
            }
            try append(fileURL: file, event: event, instance: instance, sessionID: nil, fields: fields)
        } catch {
            // best-effort
        }
    }

    public func appendToLogPath(
        _ logPath: String,
        instance: String,
        sessionID: String?,
        event: String,
        fields: [String: String] = [:]
    ) {
        do {
            let file = URL(fileURLWithPath: logPath, isDirectory: false)
            if !fileManager.fileExists(atPath: file.path) {
                _ = fileManager.createFile(atPath: file.path, contents: nil)
            }
            try append(fileURL: file, event: event, instance: instance, sessionID: sessionID, fields: fields)
        } catch {
            // best-effort
        }
    }

    private func append(
        fileURL: URL,
        event: String,
        instance: String,
        sessionID: String?,
        fields: [String: String]
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        var payload: [String: String] = [
            "ts": String(nowEpochMs()),
            "event": event,
            "instance": instance
        ]
        if let sessionID {
            payload["session_id"] = sessionID
        }
        for (k, v) in fields {
            payload[k] = v
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard var line = String(data: data, encoding: .utf8) else {
            return
        }
        line += "\n"
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
    }
}
