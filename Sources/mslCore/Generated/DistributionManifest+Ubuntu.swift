import Foundation

enum EmbeddedDistributionManifestUbuntu {
    static let entries: [DistributionManifestEntry] = [
        DistributionManifestEntry(
            id: "amazonlinux-2-arm64",
            distro: "amazonlinux",
            version: "2",
            arch: "arm64",
            tarballURL: "https://images.linuxcontainers.org/images/amazonlinux/2/arm64/default/20260304_05:22/rootfs.tar.xz",
            sha256: "ef3bbb596b90715eb3efdae7d8d5dd466fb1ad8ed62f0504009bcbf221e0cce1",
            signatureURL: "https://images.linuxcontainers.org/images/amazonlinux/2/arm64/default/20260304_05:22/SHA256SUMS.asc",
            checksumURL: "https://images.linuxcontainers.org/images/amazonlinux/2/arm64/default/20260304_05:22/SHA256SUMS",
            signatureTarget: "checksum",
            keyFingerprint: "E7FB0CAEC8173D669066514CBAEFF88C22F6E216",
            supportState: .supported,
            serviceManager: "systemd",
            defaultInitMode: nil,
            userConvergenceTemplate: UserConvergencePolicyTemplate(
                templateId: "amazonlinux-useradd-v1",
                commandFamily: "useradd",
                adminGroup: "wheel",
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
            ),
            cacheSharingDefaults: CacheSharingConfig(
                enabled: true,
                apt: false,
                apk: false,
                zypper: false,
                dnf: true
            ),
            vulnerabilityDBTarget: DistributionManifestEntry.VulnerabilityDBTarget(
                family: "redhat",
                release: "2",
                dictionary: "goval"
            )
        ),
        DistributionManifestEntry(
            id: "alpine-3.23-arm64",
            distro: "alpine",
            version: "3.23",
            arch: "arm64",
            tarballURL: "https://images.linuxcontainers.org/images/alpine/3.23/arm64/default/20260304_13:00/rootfs.tar.xz",
            sha256: "51fc4909e40cafd7fbe1566faa666837000bb4f19cde2d54e3b48fbba7ab5cd8",
            signatureURL: "https://images.linuxcontainers.org/images/alpine/3.23/arm64/default/20260304_13:00/SHA256SUMS.asc",
            checksumURL: "https://images.linuxcontainers.org/images/alpine/3.23/arm64/default/20260304_13:00/SHA256SUMS",
            signatureTarget: "checksum",
            keyFingerprint: "E7FB0CAEC8173D669066514CBAEFF88C22F6E216",
            supportState: .supported,
            serviceManager: "openrc",
            defaultInitMode: nil,
            userConvergenceTemplate: UserConvergencePolicyTemplate(
                templateId: "alpine-busybox-v1",
                commandFamily: "busybox_adduser",
                adminGroup: "wheel",
                sudoPolicy: SudoPolicyTemplate(
                    enabled: true,
                    requireSudoBinary: false,
                    dropInPath: "/etc/sudoers.d/msl-user",
                    passwordless: true
                ),
                suPolicy: SuPolicyTemplate(
                    enabled: true,
                    passwordless: true
                ),
                shellFallbacks: ["/bin/ash", "/bin/sh"],
                welcomePolicy: WelcomePolicyTemplate(
                    enabled: true,
                    frequency: "daily",
                    respectHushlogin: true
                ),
                editable: false
            ),
            cacheSharingDefaults: CacheSharingConfig(
                enabled: true,
                apt: false,
                apk: true,
                zypper: false,
                dnf: false
            ),
            vulnerabilityDBTarget: DistributionManifestEntry.VulnerabilityDBTarget(
                family: "alpine",
                release: "3.23",
                dictionary: "goval"
            )
        ),
        DistributionManifestEntry(
            id: "debian-trixie-arm64",
            distro: "debian",
            version: "trixie",
            arch: "arm64",
            tarballURL: "https://images.linuxcontainers.org/images/debian/trixie/arm64/default/20260304_05:24/rootfs.tar.xz",
            sha256: "69c5535ddd7f89799dbd1138d5851a4ae53492d706624c553900d7c2ca0ab89a",
            signatureURL: "https://images.linuxcontainers.org/images/debian/trixie/arm64/default/20260304_05:24/SHA256SUMS.asc",
            checksumURL: "https://images.linuxcontainers.org/images/debian/trixie/arm64/default/20260304_05:24/SHA256SUMS",
            signatureTarget: "checksum",
            keyFingerprint: "E7FB0CAEC8173D669066514CBAEFF88C22F6E216",
            supportState: .supported,
            serviceManager: "systemd",
            defaultInitMode: nil,
            userConvergenceTemplate: UserConvergencePolicyTemplate(
                templateId: "debian-useradd-v1",
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
            ),
            cacheSharingDefaults: CacheSharingConfig(
                enabled: true,
                apt: true,
                apk: false,
                zypper: false,
                dnf: false
            ),
            vulnerabilityDBTarget: DistributionManifestEntry.VulnerabilityDBTarget(
                family: "debian",
                release: "trixie",
                dictionary: "goval"
            )
        ),
        DistributionManifestEntry(
            id: "ubuntu-noble-arm64",
            distro: "ubuntu",
            version: "noble",
            arch: "arm64",
            tarballURL: "https://images.linuxcontainers.org/images/ubuntu/noble/arm64/default/20260304_07:42/rootfs.tar.xz",
            sha256: "60bd727dd135eacd6a43b66186b071430ede922a309f7a2ad67ed02a4675294d",
            signatureURL: "https://images.linuxcontainers.org/images/ubuntu/noble/arm64/default/20260304_07:42/SHA256SUMS.asc",
            checksumURL: "https://images.linuxcontainers.org/images/ubuntu/noble/arm64/default/20260304_07:42/SHA256SUMS",
            signatureTarget: "checksum",
            keyFingerprint: "E7FB0CAEC8173D669066514CBAEFF88C22F6E216",
            supportState: .supported,
            serviceManager: "systemd",
            defaultInitMode: nil,
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
            ),
            cacheSharingDefaults: CacheSharingConfig(
                enabled: true,
                apt: true,
                apk: false,
                zypper: false,
                dnf: false
            ),
            vulnerabilityDBTarget: DistributionManifestEntry.VulnerabilityDBTarget(
                family: "ubuntu",
                release: "noble",
                dictionary: "goval"
            )
        ),
        DistributionManifestEntry(
            id: "ubuntu-questing-arm64",
            distro: "ubuntu",
            version: "questing",
            arch: "arm64",
            tarballURL: "https://images.linuxcontainers.org/images/ubuntu/questing/arm64/default/20260304_07:42/rootfs.tar.xz",
            sha256: "2cb1040a6263e9af0fcbb14de92e20813019ba427801de9a3b197e75f7b17559",
            signatureURL: "https://images.linuxcontainers.org/images/ubuntu/questing/arm64/default/20260304_07:42/SHA256SUMS.asc",
            checksumURL: "https://images.linuxcontainers.org/images/ubuntu/questing/arm64/default/20260304_07:42/SHA256SUMS",
            signatureTarget: "checksum",
            keyFingerprint: "E7FB0CAEC8173D669066514CBAEFF88C22F6E216",
            supportState: .supported,
            serviceManager: "systemd",
            defaultInitMode: nil,
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
            ),
            cacheSharingDefaults: CacheSharingConfig(
                enabled: true,
                apt: true,
                apk: false,
                zypper: false,
                dnf: false
            ),
            vulnerabilityDBTarget: DistributionManifestEntry.VulnerabilityDBTarget(
                family: "ubuntu",
                release: "questing",
                dictionary: "goval"
            )
        ),
        DistributionManifestEntry(
            id: "fedora-43-arm64",
            distro: "fedora",
            version: "43",
            arch: "arm64",
            tarballURL: "https://images.linuxcontainers.org/images/fedora/43/arm64/default/20260304_20:33/rootfs.tar.xz",
            sha256: "4ef6c6703c8abcd13abb0797b2688944027a61703263870d919da5529add66df",
            signatureURL: "https://images.linuxcontainers.org/images/fedora/43/arm64/default/20260304_20:33/SHA256SUMS.asc",
            checksumURL: "https://images.linuxcontainers.org/images/fedora/43/arm64/default/20260304_20:33/SHA256SUMS",
            signatureTarget: "checksum",
            keyFingerprint: "E7FB0CAEC8173D669066514CBAEFF88C22F6E216",
            supportState: .supported,
            serviceManager: "systemd",
            defaultInitMode: nil,
            userConvergenceTemplate: UserConvergencePolicyTemplate(
                templateId: "fedora-useradd-v1",
                commandFamily: "useradd",
                adminGroup: "wheel",
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
            ),
            cacheSharingDefaults: CacheSharingConfig(
                enabled: true,
                apt: false,
                apk: false,
                zypper: false,
                dnf: true
            ),
            vulnerabilityDBTarget: DistributionManifestEntry.VulnerabilityDBTarget(
                family: "redhat",
                release: "43",
                dictionary: "goval"
            )
        ),
        DistributionManifestEntry(
            id: "opensuse-16.0-arm64",
            distro: "opensuse",
            version: "16.0",
            arch: "arm64",
            tarballURL: "https://images.linuxcontainers.org/images/opensuse/16.0/arm64/default/20260304_04:20/rootfs.tar.xz",
            sha256: "e5ac9ae4de4462f530704b46ffc1beb69d9b9cd1897ccd4d03327f6df8fad042",
            signatureURL: "https://images.linuxcontainers.org/images/opensuse/16.0/arm64/default/20260304_04:20/SHA256SUMS.asc",
            checksumURL: "https://images.linuxcontainers.org/images/opensuse/16.0/arm64/default/20260304_04:20/SHA256SUMS",
            signatureTarget: "checksum",
            keyFingerprint: "E7FB0CAEC8173D669066514CBAEFF88C22F6E216",
            supportState: .supported,
            serviceManager: "systemd",
            defaultInitMode: nil,
            userConvergenceTemplate: UserConvergencePolicyTemplate(
                templateId: "opensuse-useradd-v1",
                commandFamily: "useradd",
                adminGroup: "wheel",
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
            ),
            cacheSharingDefaults: CacheSharingConfig(
                enabled: true,
                apt: false,
                apk: false,
                zypper: true,
                dnf: false
            ),
            vulnerabilityDBTarget: DistributionManifestEntry.VulnerabilityDBTarget(
                family: "opensuse",
                release: "16.0",
                dictionary: "goval"
            )
        )
    ]
}
