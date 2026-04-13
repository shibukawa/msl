import Foundation

struct BundledToolRecord: Codable, Equatable {
    let name: String
    let version: String
    let checksum: String
    let relativePath: String
}

struct BundledToolManifest: Codable, Equatable {
    let bundleVersion: String
    let platform: String
    let generatedAtEpochMs: Int64?
    let tools: [BundledToolRecord]

    func record(named name: String) -> BundledToolRecord? {
        tools.first { $0.name == name }
    }
}
