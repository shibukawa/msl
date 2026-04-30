import Foundation

struct RuntimeBootProfileResolver {
    private let fallbackKernelID: String? = "slim"
    let paths: MSLPaths
    let logger: MSLLogger?
    let environment: [String: String]

    init(paths: MSLPaths, logger: MSLLogger?, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.paths = paths
        self.logger = logger
        self.environment = environment
    }

    func resolve(metadataURL: URL, instanceName: String, defaultKernelProfileRef: String?) throws -> RuntimeBootProfile {
        let metadata = try readMetadata(metadataURL: metadataURL)
        let metadataKernel = metadata.kernelProfileRef?.trimmingCharacters(in: .whitespacesAndNewlines)
        let metadataKernelRef = (metadataKernel?.isEmpty == false) ? metadataKernel : nil
        let envKernelRaw = environment["MSL_KERNEL_PROFILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let envKernelID = (envKernelRaw?.isEmpty == false) ? envKernelRaw : nil
        let kernelID = envKernelID
            ?? metadataKernelRef
            ?? defaultKernelProfileRef
            ?? fallbackKernelID

        guard let kernelID, !kernelID.isEmpty else {
            throw MSLRuntimeError(
                "kernel profile is not configured for instance '\(instanceName)'. " +
                "set metadata.kernelProfileRef or config.defaultKernelProfileRef (or export MSL_KERNEL_PROFILE)."
            )
        }

        let kernelDir = paths.kernelsDir.appendingPathComponent(kernelID, isDirectory: true)
        let kernelURL = kernelDir.appendingPathComponent("vmlinuz", isDirectory: false)
        guard FileManager.default.fileExists(atPath: kernelURL.path) else {
            throw MSLRuntimeError("Step6 kernel not found: \(kernelURL.path)")
        }

        let resolvedMode = resolveInitMode(metadata: metadata)
        let resolvedServiceManager = resolveServiceManager(metadata: metadata)
        let commandLine: String
        if let override = environment["MSL_KERNEL_CMDLINE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            commandLine = override
        } else {
            let rootRaw = environment["MSL_KERNEL_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let root = ((rootRaw?.isEmpty == false) ? rootRaw : nil) ?? "/dev/vda"
            let rootMode = metadata.resolvedRootMode()
            if rootMode == .readonlyBaseCowState {
                commandLine = "root=\(root) ro console=hvc0 init=/init"
            } else {
                let initPathRaw = environment["MSL_KERNEL_INIT_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                let defaultInitPath = resolvedMode == "service-managed-init" ? "/sbin/init" : "/sbin/msl-init-bootloader"
                let initPath = ((initPathRaw?.isEmpty == false) ? initPathRaw : nil) ?? defaultInitPath
                commandLine = "root=\(root) rw console=hvc0 init=\(initPath)"
            }
        }

        logger?.log("kernel_profile_resolved", fields: [
            "instance": instanceName,
            "kernel_id": kernelID,
            "kernel_path": kernelURL.path,
            "cmdline": commandLine,
            "init_mode": resolvedMode,
            "service_manager": resolvedServiceManager ?? "-"
        ])

        return RuntimeBootProfile(
            instanceName: instanceName,
            kernelID: kernelID,
            kernelURL: kernelURL,
            commandLine: commandLine,
            rootMode: metadata.resolvedRootMode(),
            initMode: resolvedMode,
            serviceManager: resolvedServiceManager,
            profileSource: "metadata"
        )
    }

    private func readMetadata(metadataURL: URL) throws -> DistributionInstanceMetadata {
        let data = try Data(contentsOf: metadataURL)
        return try JSONDecoder().decode(DistributionInstanceMetadata.self, from: data)
    }

    private func resolveInitMode(metadata: DistributionInstanceMetadata) -> String {
        if let envMode = environment["MSL_INIT_MODE"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           envMode == "direct-init" || envMode == "service-managed-init" {
            return envMode
        }
        if let metadataMode = metadata.runtimeProfile?.initMode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           metadataMode == "direct-init" || metadataMode == "service-managed-init" {
            return metadataMode
        }
        return "direct-init"
    }

    private func resolveServiceManager(metadata: DistributionInstanceMetadata) -> String? {
        if let envServiceManager = normalizeServiceManager(environment["MSL_SERVICE_MANAGER"]) {
            return envServiceManager
        }
        if let metadataServiceManager = normalizeServiceManager(metadata.runtimeProfile?.serviceManager) {
            return metadataServiceManager
        }
        if let distroFamily = metadata.distroFamily,
           let inferred = inferServiceManager(fromDistroLike: distroFamily) {
            return inferred
        }
        if let distro = metadata.source.distro,
           let inferred = inferServiceManager(fromDistroLike: distro) {
            return inferred
        }
        if let manifestID = metadata.source.manifestId,
           let inferred = inferServiceManager(fromDistroLike: manifestID) {
            return inferred
        }
        return nil
    }

    private func normalizeServiceManager(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        switch normalized {
        case "systemd", "openrc":
            return normalized
        default:
            return nil
        }
    }

    private func inferServiceManager(fromDistroLike value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("alpine") {
            return "openrc"
        }
        if normalized.contains("ubuntu") {
            return "systemd"
        }
        return nil
    }
}
