import Foundation
import Security

public enum ConfiguredNetworkMode: String, Codable, Equatable {
    case auto
    case vmnet
    case nat
}

public enum EffectiveNetworkMode: String, Codable, Equatable {
    case vmnetShared = "vmnet-shared"
    case nat
}

public struct ResolvedNetworkMode: Equatable {
    public var configured: ConfiguredNetworkMode
    public var effective: EffectiveNetworkMode
    public var reason: String?

    public init(
        configured: ConfiguredNetworkMode,
        effective: EffectiveNetworkMode,
        reason: String? = nil
    ) {
        self.configured = configured
        self.effective = effective
        self.reason = reason
    }
}

enum NetworkModeResolver {
    static let vmnetEntitlement = "com.apple.vm.networking"

    static func configuredMode(from config: MSLConfig?) -> ConfiguredNetworkMode {
        guard let raw = config?.network?.mode?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return .auto
        }
        return ConfiguredNetworkMode(rawValue: raw.lowercased()) ?? .auto
    }

    static func resolve(
        configured: ConfiguredNetworkMode,
        executablePath: String,
        osSupportsVMNet: Bool = supportsVMNetByOS(),
        binaryHasVMNetEntitlement: Bool? = nil
    ) -> ResolvedNetworkMode {
        switch configured {
        case .nat:
            return ResolvedNetworkMode(configured: configured, effective: .nat, reason: "configured nat mode")
        case .vmnet:
            return ResolvedNetworkMode(configured: configured, effective: .vmnetShared, reason: nil)
        case .auto:
            guard osSupportsVMNet else {
                return ResolvedNetworkMode(
                    configured: configured,
                    effective: .nat,
                    reason: "vmnet unavailable: requires macOS 26 or later"
                )
            }
            let hasEntitlement = binaryHasVMNetEntitlement ?? self.binaryHasVMNetEntitlement(executablePath: executablePath)
            guard hasEntitlement else {
                return ResolvedNetworkMode(
                    configured: configured,
                    effective: .nat,
                    reason: "vmnet unavailable: binary is not signed with com.apple.vm.networking"
                )
            }
            return ResolvedNetworkMode(
                configured: configured,
                effective: .vmnetShared,
                reason: "vmnet available"
            )
        }
    }

    static func fallbackToNAT(from resolved: ResolvedNetworkMode, reason: String) -> ResolvedNetworkMode {
        ResolvedNetworkMode(configured: resolved.configured, effective: .nat, reason: reason)
    }

    static func supportsVMNetByOS() -> Bool {
        #if canImport(vmnet) && canImport(Virtualization)
        if #available(macOS 26.0, *) {
            return true
        }
        #endif
        return false
    }

    static func binaryHasVMNetEntitlement(executablePath: String) -> Bool {
        let executableURL = URL(fileURLWithPath: executablePath) as CFURL
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(executableURL, SecCSFlags(), &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            return false
        }

        var signingInfo: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInfo
        )
        guard infoStatus == errSecSuccess,
              let info = signingInfo as? [String: Any],
              let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else {
            return false
        }

        if let boolValue = entitlements[vmnetEntitlement] as? Bool {
            return boolValue
        }
        return entitlements[vmnetEntitlement] != nil
    }

    static func shouldFallbackToNAT(configured: ConfiguredNetworkMode, error: Error) -> Bool {
        guard configured == .auto else {
            return false
        }
        let message = String(describing: error).lowercased()
        let needles = [
            "vmnet",
            "not_authorized",
            "authorization",
            "macos 26 or later",
            "sharing_service_busy",
            "invalid vmnet",
            "failed to configure vmnet",
            "failed to create vmnet"
        ]
        return needles.contains { message.contains($0) }
    }
}
