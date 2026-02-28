import Foundation

public final class StateStore {
    private let paths: MSLPaths
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(paths: MSLPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
    }

    public func loadState() throws -> RuntimeState {
        if !fileManager.fileExists(atPath: paths.stateFile.path) {
            return .initial(nowMs: nowEpochMs())
        }
        let data = try Data(contentsOf: paths.stateFile)
        return try decoder.decode(RuntimeState.self, from: data)
    }

    public func saveState(_ state: RuntimeState) throws {
        let data = try encoder.encode(state)
        try data.write(to: paths.stateFile, options: .atomic)
    }

    public func loadSessions() throws -> [SessionEntry] {
        if !fileManager.fileExists(atPath: paths.sessionsFile.path) {
            return []
        }
        let data = try Data(contentsOf: paths.sessionsFile)
        return try decoder.decode([SessionEntry].self, from: data)
    }

    public func saveSessions(_ sessions: [SessionEntry]) throws {
        let data = try encoder.encode(sessions)
        try data.write(to: paths.sessionsFile, options: .atomic)
    }

    public func loadPortMappings() throws -> PortMappingsState {
        if !fileManager.fileExists(atPath: paths.portsFile.path) {
            return PortMappingsState()
        }
        let data = try Data(contentsOf: paths.portsFile)
        return try decoder.decode(PortMappingsState.self, from: data)
    }

    public func savePortMappings(_ state: PortMappingsState) throws {
        let data = try encoder.encode(state)
        try data.write(to: paths.portsFile, options: .atomic)
    }
}
