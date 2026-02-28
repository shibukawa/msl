import Foundation

public final class MSLLogger {
    private let logFile: URL
    private let fileManager: FileManager

    public init(logFile: URL, fileManager: FileManager = .default) {
        self.logFile = logFile
        self.fileManager = fileManager
    }

    public func log(_ event: String, fields: [String: String] = [:]) {
        var payload: [String: String] = [
            "ts": String(nowEpochMs()),
            "event": event
        ]
        for (k, v) in fields {
            payload[k] = v
        }

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              var line = String(data: data, encoding: .utf8) else {
            return
        }
        line += "\n"

        if !fileManager.fileExists(atPath: logFile.path) {
            _ = fileManager.createFile(atPath: logFile.path, contents: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: logFile) else {
            return
        }
        defer { try? handle.close() }

        do {
            try handle.seekToEnd()
            if let encoded = line.data(using: .utf8) {
                try handle.write(contentsOf: encoded)
            }
        } catch {
            return
        }
    }
}
