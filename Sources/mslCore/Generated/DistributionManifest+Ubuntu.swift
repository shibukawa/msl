import Foundation

enum EmbeddedDistributionManifestUbuntu {
    static let entries: [DistributionManifestEntry] = [
        DistributionManifestEntry(
            id: "amazonlinux-2-arm64",
            distro: "amazonlinux",
            version: "2",
            arch: "arm64",
            tarballURL: "https://images.linuxcontainers.org/images/amazonlinux/2/arm64/default/20260509_05:18/rootfs.tar.xz",
            sha256: "2afb5bc22b7e154fc029341074ff8a8f54149f4a1c2649a39596c22f12cf081c",
            signatureURL: "https://images.linuxcontainers.org/images/amazonlinux/2/arm64/default/20260509_05:18/SHA256SUMS.asc",
            checksumURL: "https://images.linuxcontainers.org/images/amazonlinux/2/arm64/default/20260509_05:18/SHA256SUMS",
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
            tarballURL: "https://images.linuxcontainers.org/images/alpine/3.23/arm64/default/20260508_13:01/rootfs.tar.xz",
            sha256: "d5914c146c2f4fcedea21045f26c2e7518abfb76aacf807a0409481fd56d42ee",
            signatureURL: "https://images.linuxcontainers.org/images/alpine/3.23/arm64/default/20260508_13:01/SHA256SUMS.asc",
            checksumURL: "https://images.linuxcontainers.org/images/alpine/3.23/arm64/default/20260508_13:01/SHA256SUMS",
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
            tarballURL: "https://images.linuxcontainers.org/images/debian/trixie/arm64/default/20260509_05:24/rootfs.tar.xz",
            sha256: "ed138041e0ee988ac2b0948627688e785acabe01739e1c6947a64e52f986ecd7",
            signatureURL: "https://images.linuxcontainers.org/images/debian/trixie/arm64/default/20260509_05:24/SHA256SUMS.asc",
            checksumURL: "https://images.linuxcontainers.org/images/debian/trixie/arm64/default/20260509_05:24/SHA256SUMS",
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
            tarballURL: "https://images.linuxcontainers.org/images/ubuntu/noble/arm64/default/20260509_07:42/rootfs.tar.xz",
            sha256: "887478a057dc2113617b11640559f127a83241115c8c3c479c38ab196509ac5f",
            signatureURL: "https://images.linuxcontainers.org/images/ubuntu/noble/arm64/default/20260509_07:42/SHA256SUMS.asc",
            checksumURL: "https://images.linuxcontainers.org/images/ubuntu/noble/arm64/default/20260509_07:42/SHA256SUMS",
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
            tarballURL: "https://images.linuxcontainers.org/images/ubuntu/resolute/arm64/default/20260509_07:42/rootfs.tar.xz",
            sha256: "fdbcd73584777d8a849a43411d9c3cff7f618b97500cd62791b0b317ec355e45",
            signatureURL: "https://images.linuxcontainers.org/images/ubuntu/resolute/arm64/default/20260509_07:42/SHA256SUMS.asc",
            checksumURL: "https://images.linuxcontainers.org/images/ubuntu/resolute/arm64/default/20260509_07:42/SHA256SUMS",
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
            tarballURL: "https://images.linuxcontainers.org/images/fedora/43/arm64/default/20260508_20:33/rootfs.tar.xz",
            sha256: "94e36632ee678e21019926084510826c95cda9482f124b1a2f6230e2d24ad3c8",
            signatureURL: "https://images.linuxcontainers.org/images/fedora/43/arm64/default/20260508_20:33/SHA256SUMS.asc",
            checksumURL: "https://images.linuxcontainers.org/images/fedora/43/arm64/default/20260508_20:33/SHA256SUMS",
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
