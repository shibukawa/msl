import Foundation

struct BundledToolRecord: Codable, Equatable {
    let name: String
    let platform: String
    let version: String
    let checksum: String
    let relativePath: String

    enum CodingKeys: String, CodingKey {
        case name
        case platform
        case version
        case checksum
        case relativePath
    }

    init(name: String, platform: String, version: String, checksum: String, relativePath: String) {
        self.name = name
        self.platform = platform
        self.version = version
        self.checksum = checksum
        self.relativePath = relativePath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        platform = try container.decodeIfPresent(String.self, forKey: .platform) ?? "darwin-arm64"
        version = try container.decode(String.self, forKey: .version)
        checksum = try container.decode(String.self, forKey: .checksum)
        relativePath = try container.decode(String.self, forKey: .relativePath)
    }
}

struct BundledToolManifest: Codable, Equatable {
    let bundleVersion: String
    let generatedAtEpochMs: Int64?
    let tools: [BundledToolRecord]

    func record(named name: String, platform: String) -> BundledToolRecord? {
        tools.first { $0.name == name && $0.platform == platform }
    }

    func records(platform: String) -> [BundledToolRecord] {
        tools.filter { $0.platform == platform }
    }
}

struct ImagewriterExtraFileEntry: Codable, Equatable {
    let sourceRelativePath: String
    let guestPath: String
    let mode: String
}

struct ImagewriterExtraFilesManifest: Codable, Equatable {
    let files: [ImagewriterExtraFileEntry]
}
