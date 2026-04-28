import Foundation

enum EmbeddedDistributionManifestUbuntu {
    static let entries: [DistributionManifestEntry] = [
        DistributionManifestEntry(
            id: "amazonlinux-2-arm64",
            distro: "amazonlinux",
            version: "2",
            arch: "arm64",
            tarballURL: "https://images.linuxcontainers.org/images/amazonlinux/2/arm64/default/20260428_05:09/rootfs.tar.xz",
            sha256: "85aa5fc24ba69b92f7585df54ec931282931e550a53b092c9a02fbf6b0b16e60",
            signatureURL: "https://images.linuxcontainers.org/images/amazonlinux/2/arm64/default/20260428_05:09/SHA256SUMS.asc",
            checksumURL: "https://images.linuxcontainers.org/images/amazonlinux/2/arm64/default/20260428_05:09/SHA256SUMS",
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
            tarballURL: "https://images.linuxcontainers.org/images/alpine/3.23/arm64/default/20260427_13:00/rootfs.tar.xz",
            sha256: "522b1dd0b131021508c1fd4dd7de8ec87de829c7c3a6b2817138a87e5502f9e4",
            signatureURL: "https://images.linuxcontainers.org/images/alpine/3.23/arm64/default/20260427_13:00/SHA256SUMS.asc",
            checksumURL: "https://images.linuxcontainers.org/images/alpine/3.23/arm64/default/20260427_13:00/SHA256SUMS",
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
            tarballURL: "https://images.linuxcontainers.org/images/debian/trixie/arm64/default/20260427_05:24/rootfs.tar.xz",
            sha256: "0c00e0daf68d95043b531db16a42a3d3e9a03e8fbfc57368bdb4b74006b1d924",
            signatureURL: "https://images.linuxcontainers.org/images/debian/trixie/arm64/default/20260427_05:24/SHA256SUMS.asc",
            checksumURL: "https://images.linuxcontainers.org/images/debian/trixie/arm64/default/20260427_05:24/SHA256SUMS",
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
            id: "ubuntu-24.04-arm64",
            distro: "ubuntu",
            version: "24.04",
            arch: "arm64",
            tarballURL: "https://images.linuxcontainers.org/images/ubuntu/noble/arm64/default/20260427_07:51/rootfs.tar.xz",
            sha256: "4c7325fd3d3ce864589e541d65e45928b7f8587c0a30f655a4ff73f41073fcd5",
            signatureURL: "https://images.linuxcontainers.org/images/ubuntu/noble/arm64/default/20260427_07:51/SHA256SUMS.asc",
            checksumURL: "https://images.linuxcontainers.org/images/ubuntu/noble/arm64/default/20260427_07:51/SHA256SUMS",
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
            id: "ubuntu-26.04-arm64",
            distro: "ubuntu",
            version: "26.04",
            arch: "arm64",
            tarballURL: "https://images.linuxcontainers.org/images/ubuntu/resolute/arm64/default/20260427_07:57/rootfs.tar.xz",
            sha256: "db3696866310544b889d70dedb2762acbdebbe96badd2bad4c589b4928eecb18",
            signatureURL: "https://images.linuxcontainers.org/images/ubuntu/resolute/arm64/default/20260427_07:57/SHA256SUMS.asc",
            checksumURL: "https://images.linuxcontainers.org/images/ubuntu/resolute/arm64/default/20260427_07:57/SHA256SUMS",
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
            tarballURL: "https://images.linuxcontainers.org/images/fedora/43/arm64/default/20260427_20:33/rootfs.tar.xz",
            sha256: "4466e96fab6e861dcd710252ef71c9c133f94a43cd9cfab855969c212411e302",
            signatureURL: "https://images.linuxcontainers.org/images/fedora/43/arm64/default/20260427_20:33/SHA256SUMS.asc",
            checksumURL: "https://images.linuxcontainers.org/images/fedora/43/arm64/default/20260427_20:33/SHA256SUMS",
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
            tarballURL: "https://images.linuxcontainers.org/images/opensuse/16.0/arm64/default/20260428_04:20/rootfs.tar.xz",
            sha256: "901010fabbe971bd2efdd3d52cb7e2beb6a3bc77ae21ffe28fab0c152365063b",
            signatureURL: "https://images.linuxcontainers.org/images/opensuse/16.0/arm64/default/20260428_04:20/SHA256SUMS.asc",
            checksumURL: "https://images.linuxcontainers.org/images/opensuse/16.0/arm64/default/20260428_04:20/SHA256SUMS",
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
