import Foundation

final class DistributionManifestStore {
    private let entries: [DistributionManifestEntry]
    private let installDescriptors: [DistributionInstallDescriptor]

    init(
        entries: [DistributionManifestEntry] = EmbeddedDistributionManifest.entries,
        installDescriptors: [DistributionInstallDescriptor] = EmbeddedDistributionInstallCatalog.descriptors
    ) {
        self.entries = entries
        self.installDescriptors = installDescriptors
    }

    func allEntries() -> [DistributionManifestEntry] {
        entries
    }

    func resolve(alias: String) -> DistributionManifestEntry? {
        let normalized = alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let supportedEntries = entries.filter { $0.supportState == .supported }
        let entryByManifestID = Dictionary(uniqueKeysWithValues: supportedEntries.map { ($0.id, $0) })
        if let descriptor = descriptorByToken()[normalized] {
            return entryByManifestID[descriptor.manifestId]
        }
        return supportedEntries.first { $0.id == normalized }
    }

    func installableDescriptors() -> [DistributionInstallDescriptor] {
        let supportedManifestIDs = Set(entries.filter { $0.supportState == .supported }.map(\.id))
        return installDescriptors
            .filter { supportedManifestIDs.contains($0.manifestId) }
            .sorted { $0.canonicalName.localizedCaseInsensitiveCompare($1.canonicalName) == .orderedAscending }
    }

    func installableNames() -> [String] {
        installableDescriptors().map(\.canonicalName)
    }

    func validate(_ entry: DistributionManifestEntry) throws {
        if entry.sha256.isEmpty || entry.sha256 == "REPLACE_WITH_UPDATE_COMMAND" ||
            entry.signatureURL == "REPLACE_WITH_UPDATE_COMMAND" ||
            entry.keyFingerprint == "REPLACE_WITH_UPDATE_COMMAND" {
            throw MSLRuntimeError(
                "manifest entry '\(entry.id)' is not finalized. run `make update-distribution-list` and rebuild msl."
            )
        }
        guard URL(string: entry.tarballURL) != nil else {
            throw MSLRuntimeError("manifest entry '\(entry.id)' has invalid tarballURL")
        }
        if let signatureURL = entry.signatureURL, !signatureURL.isEmpty,
           URL(string: signatureURL) == nil {
            throw MSLRuntimeError("manifest entry '\(entry.id)' has invalid signatureURL")
        }
        if let checksumURL = entry.checksumURL, !checksumURL.isEmpty,
           URL(string: checksumURL) == nil {
            throw MSLRuntimeError("manifest entry '\(entry.id)' has invalid checksumURL")
        }
        if entry.signatureURL == nil || entry.signatureURL?.isEmpty == true {
            throw MSLRuntimeError(
                "manifest entry '\(entry.id)' is missing signatureURL. run `make update-distribution-list` and rebuild."
            )
        }
        if entry.keyFingerprint == nil || entry.keyFingerprint?.isEmpty == true {
            throw MSLRuntimeError(
                "manifest entry '\(entry.id)' is missing keyFingerprint. run `make update-distribution-list` and rebuild."
            )
        }
    }

    private func descriptorByToken() -> [String: DistributionInstallDescriptor] {
        var map: [String: DistributionInstallDescriptor] = [:]
        for descriptor in installDescriptors {
            for token in [descriptor.canonicalName] + descriptor.aliases {
                let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if normalized.isEmpty {
                    continue
                }
                if map[normalized] == nil {
                    map[normalized] = descriptor
                }
            }
        }
        return map
    }
}
