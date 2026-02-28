import Foundation

enum EmbeddedDistributionManifestUbuntu {
    static let entries: [DistributionManifestEntry] = [
        DistributionManifestEntry(
            id: "ubuntu-24.04-arm64",
            distro: "ubuntu",
            version: "24.04",
            arch: "arm64",
            tarballURL: "https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-arm64-root.tar.xz",
            sha256: "eb50d09466a96381bd1bd68d2a78f2c55be2b6d0256c5df323a35992c180e8ff",
            signatureURL: "https://cloud-images.ubuntu.com/minimal/releases/noble/release/SHA256SUMS.gpg",
            checksumURL: "https://cloud-images.ubuntu.com/minimal/releases/noble/release/SHA256SUMS",
            signatureTarget: "checksum",
            keyFingerprint: "D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81",
            supportState: .supported,
            userConvergenceTemplate: UserConvergencePolicyTemplate(
                templateId: "ubuntu-useradd-v1",
                commandFamily: "useradd",
                adminGroup: "sudo",
                sudoPolicy: SudoPolicyTemplate(
                    enabled: true,
                    requireSudoBinary: false,
                    dropInPath: "/etc/sudoers.d/msl-user",
                    passwordless: true
                ),
                suPolicy: SuPolicyTemplate(
                    enabled: false,
                    passwordless: false
                ),
                shellFallbacks: ["/bin/bash", "/bin/sh"],
                welcomePolicy: WelcomePolicyTemplate(
                    enabled: true,
                    frequency: "daily",
                    respectHushlogin: true
                ),
                editable: false
            )
        ),
        DistributionManifestEntry(
            id: "ubuntu-25.10-arm64",
            distro: "ubuntu",
            version: "25.10",
            arch: "arm64",
            tarballURL: "https://cloud-images.ubuntu.com/minimal/releases/questing/release/ubuntu-25.10-minimal-cloudimg-arm64-root.tar.xz",
            sha256: "a07a41510882f8c043ad85e8499859c7129ebdb0a72f166372cc31c365b279a9",
            signatureURL: "https://cloud-images.ubuntu.com/minimal/releases/questing/release/SHA256SUMS.gpg",
            checksumURL: "https://cloud-images.ubuntu.com/minimal/releases/questing/release/SHA256SUMS",
            signatureTarget: "checksum",
            keyFingerprint: "D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81",
            supportState: .supported,
            userConvergenceTemplate: UserConvergencePolicyTemplate(
                templateId: "ubuntu-useradd-v1",
                commandFamily: "useradd",
                adminGroup: "sudo",
                sudoPolicy: SudoPolicyTemplate(
                    enabled: true,
                    requireSudoBinary: false,
                    dropInPath: "/etc/sudoers.d/msl-user",
                    passwordless: true
                ),
                suPolicy: SuPolicyTemplate(
                    enabled: false,
                    passwordless: false
                ),
                shellFallbacks: ["/bin/bash", "/bin/sh"],
                welcomePolicy: WelcomePolicyTemplate(
                    enabled: true,
                    frequency: "daily",
                    respectHushlogin: true
                ),
                editable: false
            )
        )
    ]
}
