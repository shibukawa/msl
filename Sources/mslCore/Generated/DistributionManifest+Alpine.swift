import Foundation

enum EmbeddedDistributionManifestAlpine {
    static let entries: [DistributionManifestEntry] = [
        DistributionManifestEntry(
            id: "alpine-latest-aarch64",
            distro: "alpine",
            version: "latest",
            arch: "aarch64",
            tarballURL: "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/alpine-minirootfs-3.23.3-aarch64.tar.gz",
            sha256: "f219bb9d65febed9046951b19f2b893b331315740af32c47e39b38fcca4be543",
            signatureURL: "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/alpine-minirootfs-3.23.3-aarch64.tar.gz.asc",
            checksumURL: "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/alpine-minirootfs-3.23.3-aarch64.tar.gz.sha256",
            signatureTarget: "artifact",
            keyFingerprint: "0482D84022F52DF1C4E7CD43293ACD0907D9495A",
            supportState: .supported,
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
                apk: true
            )
        )
    ]
}
