import Foundation

enum EmbeddedDistributionManifest {
    static let entries: [DistributionManifestEntry] =
        EmbeddedDistributionManifestAlpine.entries +
        EmbeddedDistributionManifestUbuntu.entries
}
