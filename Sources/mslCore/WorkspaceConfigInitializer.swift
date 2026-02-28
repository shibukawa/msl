import Foundation

public struct WorkspaceConfigInitResult: Equatable {
    public let configFile: URL
    public let overwritten: Bool
}

struct WorkspaceConfigInitializer {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func createConfig(in directory: URL, force: Bool) throws -> WorkspaceConfigInitResult {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MSLRuntimeError("workspace directory does not exist: \(directory.path)")
        }

        let configFile = directory.appendingPathComponent(".mslconfig", isDirectory: false)
        let alreadyExists = fileManager.fileExists(atPath: configFile.path)
        if alreadyExists && !force {
            throw MSLRuntimeError(".mslconfig already exists at \(configFile.path) (use --force to overwrite)")
        }

        try Data(Self.defaultTemplate.utf8).write(to: configFile, options: .atomic)
        return WorkspaceConfigInitResult(configFile: configFile, overwritten: alreadyExists)
    }

    private static let defaultTemplate = """
# msl workspace configuration
# Presence of this file enables workspace mirror for this folder.
# Add guest-private exclusions (relative to this directory).

[workspace.excludes]
paths = ["node_modules"]
"""
}
