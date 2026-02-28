import Foundation

enum EmbeddedDistributionInstallCatalog {
    static let descriptors: [DistributionInstallDescriptor] = [
        DistributionInstallDescriptor(
            canonicalName: "alpine",
            aliases: [],
            manifestId: "alpine-latest-aarch64"
        ),
        DistributionInstallDescriptor(
            canonicalName: "ubuntu-24.04",
            aliases: ["ubuntu", "ubuntu-lts", "ubuntu-noble"],
            manifestId: "ubuntu-24.04-arm64"
        ),
        DistributionInstallDescriptor(
            canonicalName: "ubuntu-25.10",
            aliases: ["ubuntu-latest", "ubuntu-questing"],
            manifestId: "ubuntu-25.10-arm64"
        )
    ]
}
