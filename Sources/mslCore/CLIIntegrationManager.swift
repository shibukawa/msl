import Foundation

public struct CLIIntegrationStatus: Equatable {
    public var cliInstalled: Bool
    public var dockerShimInstalled: Bool
    public var localBinInPath: Bool

    public init(cliInstalled: Bool, dockerShimInstalled: Bool, localBinInPath: Bool) {
        self.cliInstalled = cliInstalled
        self.dockerShimInstalled = dockerShimInstalled
        self.localBinInPath = localBinInPath
    }
}

public final class CLIIntegrationManager {
    public static let zprofileManagedBlock = """
    # MSL
    eval "$(/Applications/MSL.app/Contents/MacOS/msl shellenv)"
    """
    private static let dockerShimMarker = "# Managed by MSL"

    private let home: URL
    private let bundledCLIURL: URL
    private let fileManager: FileManager
    private let environment: [String: String]

    public init(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundledCLIURL: URL,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.home = homeDirectoryURL
        self.bundledCLIURL = bundledCLIURL
        self.fileManager = fileManager
        self.environment = environment
    }

    public var localBinURL: URL {
        home.appendingPathComponent(".local/bin", isDirectory: true)
    }

    public var cliSymlinkURL: URL {
        localBinURL.appendingPathComponent("msl", isDirectory: false)
    }

    public var dockerShimURL: URL {
        localBinURL.appendingPathComponent("docker", isDirectory: false)
    }

    public var zprofileURL: URL {
        home.appendingPathComponent(".zprofile", isDirectory: false)
    }

    public func status() -> CLIIntegrationStatus {
        CLIIntegrationStatus(
            cliInstalled: isManagedCLISymlink(),
            dockerShimInstalled: isManagedDockerShim(),
            localBinInPath: Self.pathContainsLocalBin(path: environment["PATH"], localBinPath: localBinURL.path)
        )
    }

    public func install(includeDockerShim: Bool) throws {
        try validateInstallTargets(includeDockerShim: includeDockerShim)
        try fileManager.createDirectory(at: localBinURL, withIntermediateDirectories: true)
        try installCLISymlink()
        if includeDockerShim {
            try installDockerShim()
        } else if isManagedDockerShim() {
            try fileManager.removeItem(at: dockerShimURL)
        }
        try installZProfileBlock()
    }

    public func setDockerShimInstalled(_ installed: Bool) throws {
        guard isManagedCLISymlink() else {
            throw MSLRuntimeError("CLI must be installed before changing the docker shim")
        }
        if installed {
            try validateDockerShimTarget()
            try installDockerShim()
        } else if isManagedDockerShim() {
            try fileManager.removeItem(at: dockerShimURL)
        }
    }

    public func uninstall() throws {
        if isManagedCLISymlink() {
            try fileManager.removeItem(at: cliSymlinkURL)
        }
        if isManagedDockerShim() {
            try fileManager.removeItem(at: dockerShimURL)
        }
        try removeZProfileBlock()
    }

    public static func shellenv(homeDirectoryURL: URL, currentPATH: String?) -> String {
        let localBin = homeDirectoryURL.appendingPathComponent(".local/bin", isDirectory: true).path
        if pathContainsLocalBin(path: currentPATH, localBinPath: localBin) {
            return ""
        }
        return "export PATH=\"$HOME/.local/bin:$PATH\""
    }

    private static func pathContainsLocalBin(path: String?, localBinPath: String) -> Bool {
        guard let path else { return false }
        return path.split(separator: ":").map(String.init).contains(localBinPath)
    }

    private func installCLISymlink() throws {
        guard fileManager.fileExists(atPath: bundledCLIURL.path) else {
            throw MSLRuntimeError("bundled CLI not found: \(bundledCLIURL.path)")
        }
        if isManagedCLISymlink() {
            return
        }
        if fileManager.fileExists(atPath: cliSymlinkURL.path) || isSymlink(at: cliSymlinkURL) {
            throw MSLRuntimeError("refusing to overwrite existing CLI path: \(cliSymlinkURL.path)")
        }
        try fileManager.createSymbolicLink(at: cliSymlinkURL, withDestinationURL: bundledCLIURL)
    }

    private func validateInstallTargets(includeDockerShim: Bool) throws {
        if !isManagedCLISymlink(),
           fileManager.fileExists(atPath: cliSymlinkURL.path) || isSymlink(at: cliSymlinkURL) {
            throw MSLRuntimeError("refusing to overwrite existing CLI path: \(cliSymlinkURL.path)")
        }
        if includeDockerShim {
            try validateDockerShimTarget()
        }
    }

    private func validateDockerShimTarget() throws {
        if !isManagedDockerShim(),
           fileManager.fileExists(atPath: dockerShimURL.path) || isSymlink(at: dockerShimURL) {
            throw MSLRuntimeError("refusing to overwrite existing docker path: \(dockerShimURL.path)")
        }
    }

    private func installDockerShim() throws {
        if isManagedDockerShim() {
            return
        }
        if fileManager.fileExists(atPath: dockerShimURL.path) || isSymlink(at: dockerShimURL) {
            throw MSLRuntimeError("refusing to overwrite existing docker path: \(dockerShimURL.path)")
        }
        let script = """
        #!/bin/sh
        \(Self.dockerShimMarker)
        exec "$HOME/.local/bin/msl" nerdctl "$@"
        """
        try Data((script + "\n").utf8).write(to: dockerShimURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dockerShimURL.path)
    }

    private func installZProfileBlock() throws {
        let existing = (try? String(contentsOf: zprofileURL, encoding: .utf8)) ?? ""
        guard !existing.contains(Self.zprofileManagedBlock) else { return }
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        let prefix = existing.isEmpty ? "" : "\n"
        let updated = existing + separator + prefix + Self.zprofileManagedBlock + "\n"
        try Data(updated.utf8).write(to: zprofileURL, options: .atomic)
    }

    private func removeZProfileBlock() throws {
        guard fileManager.fileExists(atPath: zprofileURL.path) else { return }
        let existing = try String(contentsOf: zprofileURL, encoding: .utf8)
        var updated = existing.replacingOccurrences(of: Self.zprofileManagedBlock + "\n", with: "")
        updated = updated.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        try Data(updated.utf8).write(to: zprofileURL, options: .atomic)
    }

    private func isManagedCLISymlink() -> Bool {
        guard isSymlink(at: cliSymlinkURL),
              let destination = try? fileManager.destinationOfSymbolicLink(atPath: cliSymlinkURL.path) else {
            return false
        }
        let resolved = URL(fileURLWithPath: destination, relativeTo: cliSymlinkURL.deletingLastPathComponent())
            .standardizedFileURL
        return resolved.path == bundledCLIURL.standardizedFileURL.path
    }

    private func isManagedDockerShim() -> Bool {
        guard let content = try? String(contentsOf: dockerShimURL, encoding: .utf8) else {
            return false
        }
        return content.contains(Self.dockerShimMarker) && content.contains("msl\" nerdctl")
    }

    private func isSymlink(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]) else {
            return false
        }
        return values.isSymbolicLink == true
    }
}
