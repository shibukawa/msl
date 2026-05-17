import Foundation

struct PrebuildResolver {
    let paths: MSLPaths
    let environment: [String: String]
    let fileManager: FileManager
    private let bundleResourcesURL: URL?

    init(
        paths: MSLPaths,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        bundleResourcesURL: URL? = nil
    ) {
        self.paths = paths
        self.environment = environment
        self.fileManager = fileManager
        if let override = environment["MSL_BUNDLE_RESOURCES_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            self.bundleResourcesURL = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            self.bundleResourcesURL = bundleResourcesURL ?? Bundle.main.resourceURL
        }
    }

    var bundledPrebuildsRoot: URL? {
        bundleResourcesURL?.appendingPathComponent("prebuilds", isDirectory: true)
    }

    func kernelDirectory(profile: String) -> URL? {
        firstExistingDirectory([
            paths.kernelsDir.appendingPathComponent(profile, isDirectory: true),
            paths.prebuildOverridesDir.appendingPathComponent("kernels/\(profile)", isDirectory: true),
            bundledPrebuildsRoot?.appendingPathComponent("kernels/\(profile)", isDirectory: true)
        ])
    }

    func guestBinary(envVar: String, name: String) -> URL? {
        firstExecutable([
            paths.prebuildOverridesDir.appendingPathComponent("guest-tools/\(name)", isDirectory: false),
            explicitPath(envVar),
            bundledPrebuildsRoot?.appendingPathComponent("guest-tools/\(name)", isDirectory: false)
        ])
    }

    func hostTool(envVar: String, name: String) -> URL? {
        firstExecutable([
            paths.prebuildOverridesDir.appendingPathComponent("host-tools/\(name)", isDirectory: false),
            explicitPath(envVar),
            bundledPrebuildsRoot?.appendingPathComponent("host-tools/\(name)", isDirectory: false)
        ])
    }

    func imagewriterBuildScript() -> URL? {
        firstExistingFile([
            paths.prebuildOverridesDir.appendingPathComponent("scripts/imagewriter-build.sh", isDirectory: false),
            explicitPath("MSL_IMAGEWRITER_BUILD_SCRIPT"),
            bundledPrebuildsRoot?.appendingPathComponent("scripts/imagewriter-build.sh", isDirectory: false)
        ])
    }

    func internalRuntimeArtifactDirectory(named name: String) -> URL? {
        firstExistingDirectory([
            paths.prebuildOverridesDir.appendingPathComponent("internal-runtimes/\(name)", isDirectory: true),
            bundledPrebuildsRoot?.appendingPathComponent("internal-runtimes/\(name)", isDirectory: true)
        ])
    }

    func containerToolCandidateDirectories() -> [URL] {
        compactUnique([
            paths.prebuildOverridesDir.appendingPathComponent("container-tools", isDirectory: true),
            explicitPath("MSL_BUNDLED_CONTAINER_TOOLS_DIR"),
            bundledPrebuildsRoot?.appendingPathComponent("container-tools", isDirectory: true)
        ])
    }

    private func explicitPath(_ name: String) -> URL? {
        guard let raw = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: raw)
    }

    private func firstExistingDirectory(_ candidates: [URL?]) -> URL? {
        candidates.compactMap { $0 }.first { candidate in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    private func firstExistingFile(_ candidates: [URL?]) -> URL? {
        candidates.compactMap { $0 }.first { candidate in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
    }

    private func firstExecutable(_ candidates: [URL?]) -> URL? {
        candidates.compactMap { $0 }.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private func compactUnique(_ candidates: [URL?]) -> [URL] {
        var seen: Set<String> = []
        return candidates.compactMap { $0 }.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
