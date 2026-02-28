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
        let metadataKernel = try readKernelProfileRefFromMetadata(metadataURL: metadataURL)
        let envKernelRaw = environment["MSL_KERNEL_PROFILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let envKernelID = (envKernelRaw?.isEmpty == false) ? envKernelRaw : nil
        let kernelID = envKernelID
            ?? metadataKernel
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

        let commandLine: String
        if let override = environment["MSL_KERNEL_CMDLINE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            commandLine = override
        } else {
            let rootRaw = environment["MSL_KERNEL_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let root = ((rootRaw?.isEmpty == false) ? rootRaw : nil) ?? "/dev/vda"
            let initPathRaw = environment["MSL_KERNEL_INIT_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let initPath = ((initPathRaw?.isEmpty == false) ? initPathRaw : nil) ?? "/sbin/msl-init"
            commandLine = "root=\(root) rw console=hvc0 init=\(initPath)"
        }

        logger?.log("kernel_profile_resolved", fields: [
            "instance": instanceName,
            "kernel_id": kernelID,
            "kernel_path": kernelURL.path,
            "cmdline": commandLine
        ])

        return RuntimeBootProfile(
            instanceName: instanceName,
            kernelID: kernelID,
            kernelURL: kernelURL,
            commandLine: commandLine
        )
    }

    private func readKernelProfileRefFromMetadata(metadataURL: URL) throws -> String? {
        let data = try Data(contentsOf: metadataURL)
        if let distribution = try? JSONDecoder().decode(DistributionInstanceMetadata.self, from: data),
           let ref = distribution.kernelProfileRef?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ref.isEmpty {
            return ref
        }
        return nil
    }
}
