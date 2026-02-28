import Foundation

public struct CompressionPathPolicyEntry: Codable, Equatable {
    public let path: String
    public let mode: String

    public init(path: String, mode: String) {
        self.path = path
        self.mode = mode
    }
}

public struct CompressionCachePolicyCatalog: Codable, Equatable {
    public let schema: Int
    public let presets: [String: [CompressionPathPolicyEntry]]

    public init(schema: Int, presets: [String: [CompressionPathPolicyEntry]]) {
        self.schema = schema
        self.presets = presets
    }

    public static func `default`() -> CompressionCachePolicyCatalog {
        CompressionCachePolicyCatalog(
            schema: 1,
            presets: [
                "docker": [
                    CompressionPathPolicyEntry(path: "/var/lib/docker", mode: "none")
                ],
                "go": [
                    CompressionPathPolicyEntry(path: "/var/cache/go-build", mode: "zstd:1")
                ],
                "apt": [
                    CompressionPathPolicyEntry(path: "/var/cache/apt", mode: "none")
                ],
                "apk": [
                    CompressionPathPolicyEntry(path: "/var/cache/apk", mode: "none")
                ]
            ]
        )
    }
}

public final class CompressionCachePolicyCatalogStore {
    private let paths: MSLPaths
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(paths: MSLPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public var catalogFile: URL {
        paths.compressionCachePolicyCatalogFile
    }

    @discardableResult
    public func ensureDefaultCatalogIfMissing() throws -> Bool {
        if fileManager.fileExists(atPath: catalogFile.path) {
            return false
        }
        try fileManager.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
        let data = try encoder.encode(CompressionCachePolicyCatalog.default())
        try data.write(to: catalogFile, options: .atomic)
        return true
    }

    public func loadCatalog() throws -> CompressionCachePolicyCatalog {
        let data = try Data(contentsOf: catalogFile)
        return try decoder.decode(CompressionCachePolicyCatalog.self, from: data)
    }

    public func merge(
        basePolicies: [CompressionPathPolicyEntry],
        cacheToggles: [String: Bool]
    ) throws -> [CompressionPathPolicyEntry] {
        let catalog = try loadCatalog()
        var merged = basePolicies

        for (cacheName, isEnabled) in cacheToggles where isEnabled {
            guard let extra = catalog.presets[cacheName], !extra.isEmpty else {
                continue
            }
            merged.append(contentsOf: extra)
        }

        var indexByPath: [String: Int] = [:]
        var result: [CompressionPathPolicyEntry] = []
        for entry in merged {
            if let existing = indexByPath[entry.path] {
                result[existing] = entry
            } else {
                indexByPath[entry.path] = result.count
                result.append(entry)
            }
        }

        return result
    }
}
