import Foundation

final class DefaultInstanceStore {
    private let paths: MSLPaths
    private let fileManager: FileManager

    init(paths: MSLPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    func loadConfig() throws -> MSLConfig {
        try ensureConfigFile()
        let data = try Data(contentsOf: paths.configFile)
        if data.trimmingWhitespaceAndNewlines.isEmpty {
            return MSLConfig(schemaVersion: 1, defaultInstanceName: nil, defaultKernelProfileRef: nil)
        }
        var config = try JSONDecoder().decode(MSLConfig.self, from: data)
        if config.schemaVersion == nil {
            config.schemaVersion = 1
        }
        return config
    }

    func saveConfig(_ config: MSLConfig) throws {
        var normalized = config
        if normalized.schemaVersion == nil {
            normalized.schemaVersion = 1
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(normalized)
        try data.write(to: paths.configFile, options: .atomic)
    }

    func loadDefaultInstanceName() throws -> String? {
        let config = try loadConfig()
        guard let name = config.defaultInstanceName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return nil
        }
        return name
    }

    func setDefaultInstanceName(_ name: String?) throws {
        var config = try loadConfig()
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            config.defaultInstanceName = name
        } else {
            config.defaultInstanceName = nil
        }
        config.schemaVersion = 1
        try saveConfig(config)
    }

    func loadDefaultKernelProfileRef() throws -> String? {
        let config = try loadConfig()
        guard let kernelID = config.defaultKernelProfileRef?.trimmingCharacters(in: .whitespacesAndNewlines),
              !kernelID.isEmpty else {
            return nil
        }
        return kernelID
    }

    func setDefaultKernelProfileRef(_ kernelID: String?) throws {
        var config = try loadConfig()
        if let kernelID = kernelID?.trimmingCharacters(in: .whitespacesAndNewlines), !kernelID.isEmpty {
            config.defaultKernelProfileRef = kernelID
        } else {
            config.defaultKernelProfileRef = nil
        }
        config.schemaVersion = 1
        try saveConfig(config)
    }

    func loadStorageCacheToggles() throws -> [String: Bool] {
        let config = try loadConfig()
        var toggles: [String: Bool] = [
            "docker": false,
            "go": true,
            "apt": true,
            "apk": true
        ]
        if let overrides = config.storageCacheToggles {
            for (rawName, isEnabled) in overrides {
                let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !name.isEmpty else { continue }
                toggles[name] = isEnabled
            }
        }
        return toggles
    }

    func setStorageCacheToggle(name rawName: String, enabled: Bool) throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else {
            throw MSLRuntimeError("cache toggle name must not be empty")
        }
        var config = try loadConfig()
        var toggles = config.storageCacheToggles ?? [:]
        toggles[name] = enabled
        config.storageCacheToggles = toggles
        config.schemaVersion = 1

        try saveConfig(config)
    }

    private func ensureConfigFile() throws {
        try fileManager.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: paths.configFile.path) {
            try Data("{}\n".utf8).write(to: paths.configFile, options: .atomic)
        }
    }
}

private extension Data {
    var trimmingWhitespaceAndNewlines: Data {
        guard let text = String(data: self, encoding: .utf8) else { return self }
        return Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    }
}
