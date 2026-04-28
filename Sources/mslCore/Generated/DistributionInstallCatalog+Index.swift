import Foundation

enum EmbeddedDistributionInstallCatalog {
    static let descriptors: [DistributionInstallDescriptor] = [
        DistributionInstallDescriptor(
            canonicalName: "amazonlinux-2",
            aliases: ["amazonlinux"],
            manifestId: "amazonlinux-2-arm64"
        ),
        DistributionInstallDescriptor(
            canonicalName: "alpine-3.23",
            aliases: ["alpine"],
            manifestId: "alpine-3.23-arm64"
        ),
        DistributionInstallDescriptor(
            canonicalName: "debian-trixie",
            aliases: ["debian", "debian-latest"],
            manifestId: "debian-trixie-arm64"
        ),
        DistributionInstallDescriptor(
            canonicalName: "ubuntu-24.04",
            aliases: ["ubuntu"],
            manifestId: "ubuntu-24.04-arm64"
        ),
        DistributionInstallDescriptor(
            canonicalName: "ubuntu-26.04",
            aliases: ["ubuntu-latest", "ubuntu-lts"],
            manifestId: "ubuntu-26.04-arm64"
        ),
        DistributionInstallDescriptor(
            canonicalName: "fedora-43",
            aliases: ["fedora", "fedora-latest"],
            manifestId: "fedora-43-arm64"
        ),
        DistributionInstallDescriptor(
            canonicalName: "opensuse-16.0",
            aliases: ["opensuse"],
            manifestId: "opensuse-16.0-arm64"
        )
    ]
}
