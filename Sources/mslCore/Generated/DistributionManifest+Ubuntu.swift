import Foundation

enum EmbeddedDistributionManifestUbuntu {
    static let entries: [DistributionManifestEntry] = [
        DistributionManifestEntry(
            id: "amazonlinux-2-arm64",
            distro: "amazonlinux",
            version: "2",
            arch: "arm64",
            tarballURL: "https://images.linuxcontainers.org/images/amazonlinux/2/arm64/default/20260501_05:09/rootfs.tar.xz",
            sha256: "b373b25d0db9d83c6954eeaae02f84c5211bf5cda145a6bf3d3c738763b9e8e7",
            signatureURL: "https://images.linuxcontainers.org/images/amazonlinux/2/arm64/default/20260501_05:09/SHA256SUMS.asc",
            checksumURL: "https://images.linuxcontainers.org/images/amazonlinux/2/arm64/default/20260501_05:09/SHA256SUMS",
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
            tarballURL: "https://images.linuxcontainers.org/images/alpine/3.23/arm64/default/20260430_13:02/rootfs.tar.xz",
            sha256: "1508b4566d6b303b987ea274e6990f9e8a25a4de96e52cfff4eb7c5d1b338427",
            signatureURL: "https://images.linuxcontainers.org/images/alpine/3.23/arm64/default/20260430_13:02/SHA256SUMS.asc",
            checksumURL: "https://images.linuxcontainers.org/images/alpine/3.23/arm64/default/20260430_13:02/SHA256SUMS",
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
            tarballURL: "https://images.linuxcontainers.org/images/debian/trixie/arm64/default/20260501_05:24/rootfs.tar.xz",
            sha256: "a39374348d73efc02c1fb39a8fe4a5f3435fd2ed59068c97604662623b32b3dd",
            signatureURL: "https://images.linuxcontainers.org/images/debian/trixie/arm64/default/20260501_05:24/SHA256SUMS.asc",
            checksumURL: "https://images.linuxcontainers.org/images/debian/trixie/arm64/default/20260501_05:24/SHA256SUMS",
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
            tarballURL: "https://images.linuxcontainers.org/images/ubuntu/noble/arm64/default/20260430_08:00/rootfs.tar.xz",
            sha256: "3cdbd6cacd62462ac32a988096e9d5a4252060657c1ec23b692aa1f64d83292d",
            signatureURL: "https://images.linuxcontainers.org/images/ubuntu/noble/arm64/default/20260430_08:00/SHA256SUMS.asc",
            checksumURL: "https://images.linuxcontainers.org/images/ubuntu/noble/arm64/default/20260430_08:00/SHA256SUMS",
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
            tarballURL: "https://images.linuxcontainers.org/images/ubuntu/resolute/arm64/default/20260430_07:58/rootfs.tar.xz",
            sha256: "4e2f81638ce81c3e83e8ffe039e205a2ab12e98cacca70df44d87076133657d8",
            signatureURL: "https://images.linuxcontainers.org/images/ubuntu/resolute/arm64/default/20260430_07:58/SHA256SUMS.asc",
            checksumURL: "https://images.linuxcontainers.org/images/ubuntu/resolute/arm64/default/20260430_07:58/SHA256SUMS",
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
            tarballURL: "https://images.linuxcontainers.org/images/fedora/43/arm64/default/20260430_20:33/rootfs.tar.xz",
            sha256: "4dce0f7f355e13978c6d754f85c158b094def707e5a2c3ec1d12d13b4cb6a60a",
            signatureURL: "https://images.linuxcontainers.org/images/fedora/43/arm64/default/20260430_20:33/SHA256SUMS.asc",
            checksumURL: "https://images.linuxcontainers.org/images/fedora/43/arm64/default/20260430_20:33/SHA256SUMS",
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
