import Foundation

public struct ResolvedCacheSharingPolicy: Equatable {
    public var enabled: Bool
    public var apt: Bool
    public var apk: Bool
    public var zypper: Bool
    public var dnf: Bool
    public var go: Bool
    public var python: Bool
    public var npm: Bool
    public var pnpm: Bool
    public var yarn: Bool
    public var maven: Bool
    public var gradle: Bool
    public var composer: Bool
    public var scala: Bool
    public var ruby: Bool
    public var rust: Bool
    public var deno: Bool
    public var bun: Bool
    public var nuget: Bool

    public static let disabled = ResolvedCacheSharingPolicy(
        enabled: false,
        apt: false,
        apk: false,
        zypper: false,
        dnf: false,
        go: false,
        python: false,
        npm: false,
        pnpm: false,
        yarn: false,
        maven: false,
        gradle: false,
        composer: false,
        scala: false,
        ruby: false,
        rust: false,
        deno: false,
        bun: false,
        nuget: false
    )
}

public enum CacheSharingPolicyResolver {
    public static func resolve(config: CacheSharingConfig?) -> ResolvedCacheSharingPolicy {
        let enabled = config?.enabled ?? false
        guard enabled else {
            return .disabled
        }
        return ResolvedCacheSharingPolicy(
            enabled: true,
            apt: config?.apt ?? true,
            apk: config?.apk ?? true,
            zypper: config?.zypper ?? false,
            dnf: config?.dnf ?? false,
            go: config?.go ?? false,
            python: config?.python ?? false,
            npm: config?.npm ?? false,
            pnpm: config?.pnpm ?? false,
            yarn: config?.yarn ?? false,
            maven: config?.maven ?? false,
            gradle: config?.gradle ?? false,
            composer: config?.composer ?? false,
            scala: config?.scala ?? false,
            ruby: config?.ruby ?? false,
            rust: config?.rust ?? false,
            deno: config?.deno ?? false,
            bun: config?.bun ?? false,
            nuget: config?.nuget ?? false
        )
    }

    public static func defaultConfigForDistroFamily(_ distroFamily: String?) -> CacheSharingConfig {
        let normalized = distroFamily?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "alpine":
            return CacheSharingConfig(enabled: true, apt: false, apk: true)
        case "ubuntu":
            return CacheSharingConfig(enabled: true, apt: true, apk: false)
        case "debian":
            return CacheSharingConfig(enabled: true, apt: true, apk: false)
        case "opensuse":
            return CacheSharingConfig(enabled: true, apt: false, apk: false, zypper: true)
        case "fedora":
            return CacheSharingConfig(enabled: true, apt: false, apk: false, dnf: true)
        default:
            return CacheSharingConfig(enabled: true)
        }
    }

    public static func hostCacheRootPath(hostHome: String) -> String {
        let base = hostHome.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty {
            return "/Library/Application Support/msl/caches"
        }
        return base + "/Library/Application Support/msl/caches"
    }

    public static func guestPathForHostPath(hostPath: String, hostShareRoot: String) -> String? {
        let normalizedHost = normalizeAbsolutePath(hostPath)
        let normalizedRoot = normalizeAbsolutePath(hostShareRoot)
        guard normalizedHost.hasPrefix("/") && normalizedRoot.hasPrefix("/") else {
            return nil
        }
        if normalizedRoot == "/" {
            return "/mnt/macos" + normalizedHost
        }
        guard normalizedHost == normalizedRoot || normalizedHost.hasPrefix(normalizedRoot + "/") else {
            return nil
        }
        let suffix = String(normalizedHost.dropFirst(normalizedRoot.count))
        return suffix.isEmpty ? "/mnt/macos" : "/mnt/macos" + suffix
    }

    public static func environment(guestCacheRoot: String, policy: ResolvedCacheSharingPolicy) -> [String: String] {
        _ = guestCacheRoot
        _ = policy
        // Step23 default policy prefers bind-mounting caches to each tool's
        // canonical path. Keep env injection empty unless a fallback is needed.
        return [:]
    }

    public static func toolFlagList(policy: ResolvedCacheSharingPolicy) -> [String: Bool] {
        [
            "apt": policy.apt,
            "apk": policy.apk,
            "zypper": policy.zypper,
            "dnf": policy.dnf,
            "go": policy.go,
            "python": policy.python,
            "npm": policy.npm,
            "pnpm": policy.pnpm,
            "yarn": policy.yarn,
            "maven": policy.maven,
            "gradle": policy.gradle,
            "composer": policy.composer,
            "scala": policy.scala,
            "ruby": policy.ruby,
            "rust": policy.rust,
            "deno": policy.deno,
            "bun": policy.bun,
            "nuget": policy.nuget,
        ]
    }

    private static func normalizeAbsolutePath(_ value: String) -> String {
        var path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty {
            return path
        }
        if path.count > 1, path.hasSuffix("/") {
            while path.count > 1, path.hasSuffix("/") {
                path.removeLast()
            }
        }
        return path
    }
}
