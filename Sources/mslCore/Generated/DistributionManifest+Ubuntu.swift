import Foundation

enum EmbeddedDistributionManifestUbuntu {
    static let entries: [DistributionManifestEntry] = [
        DistributionManifestEntry(
            id: "amazonlinux-2-arm64",
            distro: "amazonlinux",
            version: "2",
            arch: "arm64",
            tarballURL: "https://images.linuxcontainers.org/images/amazonlinux/2/arm64/default/20260410_05:09/rootfs.tar.xz",
            sha256: "18768d217f6d1c993925f04ecb5b56c10fbde77c7170fbd741f73ea9af4fc221",
            signatureURL: "https://images.linuxcontainers.org/images/amazonlinux/2/arm64/default/20260410_05:09/SHA256SUMS.asc",
            checksumURL: "https://images.linuxcontainers.org/images/amazonlinux/2/arm64/default/20260410_05:09/SHA256SUMS",
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
            )
        ),
        DistributionManifestEntry(
            id: "alpine-3.23-arm64",
            distro: "alpine",
            version: "3.23",
            arch: "arm64",
            tarballURL: "https://images.linuxcontainers.org/images/alpine/3.23/arm64/default/20260331_13:00/rootfs.tar.xz",
            sha256: "b0d4b0baedd2363394a47d6e35434ef22221a530844c57855ec8bdb34202e054",
            signatureURL: "https://images.linuxcontainers.org/images/alpine/3.23/arm64/default/20260331_13:00/SHA256SUMS.asc",
            checksumURL: "https://images.linuxcontainers.org/images/alpine/3.23/arm64/default/20260331_13:00/SHA256SUMS",
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
            )
        ),
        DistributionManifestEntry(
            id: "debian-trixie-arm64",
            distro: "debian",
            version: "trixie",
            arch: "arm64",
            tarballURL: "https://images.linuxcontainers.org/images/debian/trixie/arm64/default/20260410_05:24/rootfs.tar.xz",
            sha256: "63083b95203c316f19bc27ab796274d1f73547bc5204c538af0149f8d55364a2",
            signatureURL: "https://images.linuxcontainers.org/images/debian/trixie/arm64/default/20260410_05:24/SHA256SUMS.asc",
            checksumURL: "https://images.linuxcontainers.org/images/debian/trixie/arm64/default/20260410_05:24/SHA256SUMS",
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
            )
        ),
        DistributionManifestEntry(
            id: "ubuntu-noble-arm64",
            distro: "ubuntu",
            version: "noble",
            arch: "arm64",
            tarballURL: "https://images.linuxcontainers.org/images/ubuntu/noble/arm64/default/20260410_07:42/rootfs.tar.xz",
            sha256: "7892efe94cb99738d0c6285a887858923f3c6fc3d80e7eebd58d410846e1e32a",
            signatureURL: "https://images.linuxcontainers.org/images/ubuntu/noble/arm64/default/20260410_07:42/SHA256SUMS.asc",
            checksumURL: "https://images.linuxcontainers.org/images/ubuntu/noble/arm64/default/20260410_07:42/SHA256SUMS",
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
            )
        ),
        DistributionManifestEntry(
            id: "ubuntu-questing-arm64",
            distro: "ubuntu",
            version: "questing",
            arch: "arm64",
            tarballURL: "https://images.linuxcontainers.org/images/ubuntu/questing/arm64/default/20260410_07:42/rootfs.tar.xz",
            sha256: "0786bfcf36ea3c90cafe5b2f92aeeb0f1b89d7eb873658181ea20c0256f25680",
            signatureURL: "https://images.linuxcontainers.org/images/ubuntu/questing/arm64/default/20260410_07:42/SHA256SUMS.asc",
            checksumURL: "https://images.linuxcontainers.org/images/ubuntu/questing/arm64/default/20260410_07:42/SHA256SUMS",
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
            )
        ),
        DistributionManifestEntry(
            id: "fedora-43-arm64",
            distro: "fedora",
            version: "43",
            arch: "arm64",
            tarballURL: "https://images.linuxcontainers.org/images/fedora/43/arm64/default/20260409_20:33/rootfs.tar.xz",
            sha256: "14e259608cfec3bb57ccef195d18637a90b94387c44c2086ea7b14f10c57263b",
            signatureURL: "https://images.linuxcontainers.org/images/fedora/43/arm64/default/20260409_20:33/SHA256SUMS.asc",
            checksumURL: "https://images.linuxcontainers.org/images/fedora/43/arm64/default/20260409_20:33/SHA256SUMS",
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
            )
        ),
        DistributionManifestEntry(
            id: "opensuse-16.0-arm64",
            distro: "opensuse",
            version: "16.0",
            arch: "arm64",
            tarballURL: "https://images.linuxcontainers.org/images/opensuse/16.0/arm64/default/20260410_04:20/rootfs.tar.xz",
            sha256: "7c10380ef04107f6c65eddbba6fdd9cb05c3a23ff5ef78c631bfa3896ae6382c",
            signatureURL: "https://images.linuxcontainers.org/images/opensuse/16.0/arm64/default/20260410_04:20/SHA256SUMS.asc",
            checksumURL: "https://images.linuxcontainers.org/images/opensuse/16.0/arm64/default/20260410_04:20/SHA256SUMS",
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
            )
        )
    ]
}
