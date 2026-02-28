import Foundation

public struct WorkspaceConfig: Equatable {
    public var excludes: [String]

    public init(excludes: [String]) {
        self.excludes = excludes
    }
}

public struct WorkspaceExcludeOverlay: Equatable {
    public var relativePath: String
    public var excludedGuestPath: String
    public var overlayBackingPath: String

    public init(relativePath: String, excludedGuestPath: String, overlayBackingPath: String) {
        self.relativePath = relativePath
        self.excludedGuestPath = excludedGuestPath
        self.overlayBackingPath = overlayBackingPath
    }
}

public struct WorkspaceConfigLoader {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func load(fromWorkspaceDirectory directory: URL) throws -> WorkspaceConfig? {
        let configURL = directory.appendingPathComponent(".mslconfig", isDirectory: false)
        guard fileManager.fileExists(atPath: configURL.path) else {
            return nil
        }
        let raw = try String(contentsOf: configURL, encoding: .utf8)
        return try WorkspaceConfigParser.parse(raw)
    }
}

public enum WorkspaceConfigParseError: Error, Equatable, CustomStringConvertible {
    case invalidToml(message: String)
    case invalidExcludePath(path: String, reason: String)
    case invalidWorkspaceGuestPath(path: String)

    public var description: String {
        switch self {
        case .invalidToml(let message):
            return "invalid .mslconfig TOML: \(message)"
        case .invalidExcludePath(let path, let reason):
            return "invalid workspace exclude path '\(path)': \(reason)"
        case .invalidWorkspaceGuestPath(let path):
            return "invalid workspace guest path '\(path)'"
        }
    }
}

public struct WorkspaceExcludePlanner {
    public static let overlayRoot = "/var/opt/msl/overlay"

    public init() {}

    public func plan(workspaceGuestPath: String, excludes: [String]) throws -> [WorkspaceExcludeOverlay] {
        let basePath = try Self.normalizedWorkspaceGuestPath(workspaceGuestPath)
        var result: [WorkspaceExcludeOverlay] = []
        var seen: Set<String> = []

        for raw in excludes {
            let relative = try WorkspaceConfigParser.validateExcludeRelativePath(raw)
            let excludedGuestPath = basePath == "/" ? "/\(relative)" : "\(basePath)/\(relative)"
            if seen.contains(excludedGuestPath) {
                continue
            }
            seen.insert(excludedGuestPath)
            let overlay = "\(Self.overlayRoot)\(excludedGuestPath)"
            result.append(
                WorkspaceExcludeOverlay(
                    relativePath: relative,
                    excludedGuestPath: excludedGuestPath,
                    overlayBackingPath: overlay
                )
            )
        }
        return result
    }

    static func normalizedWorkspaceGuestPath(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else {
            throw WorkspaceConfigParseError.invalidWorkspaceGuestPath(path: raw)
        }
        var normalized = trimmed
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}

public enum WorkspaceActivationState: Equatable {
    case enabled(config: WorkspaceConfig, workspaceGuestPath: String)
    case disabled(reason: String)
}

public struct WorkspaceActivationResolver {
    public static let defaultProtectedGuestPathPrefixes: [String] = [
        "/usr",
        "/usr/local",
        "/etc",
        "/bin",
        "/sbin",
        "/lib",
        "/lib64",
        "/root"
    ]

    private let loader: WorkspaceConfigLoader
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.loader = WorkspaceConfigLoader(fileManager: fileManager)
    }

    public func resolve(launchDirectory: URL, workspacePolicy: WorkspacePolicy?) throws -> WorkspaceActivationState {
        if let workspacePolicy, workspacePolicy.startupMountEnabled == false {
            return .disabled(reason: "startup_mount_disabled")
        }
        guard let config = try loader.load(fromWorkspaceDirectory: launchDirectory) else {
            return .disabled(reason: "workspace_config_missing")
        }
        let workspaceGuestPath = try canonicalWorkspacePath(for: launchDirectory)
        if !fileManager.isReadableFile(atPath: workspaceGuestPath) {
            return .disabled(reason: "workspace_permission_denied")
        }
        let protectedPrefixes = workspacePolicy?.protectedGuestPathPrefixes ?? Self.defaultProtectedGuestPathPrefixes
        if isProtectedGuestPath(workspaceGuestPath, prefixes: protectedPrefixes) {
            return .disabled(reason: "workspace_protected_path")
        }
        return .enabled(config: config, workspaceGuestPath: workspaceGuestPath)
    }

    private func canonicalWorkspacePath(for launchDirectory: URL) throws -> String {
        let rawPath = launchDirectory.path
        guard fileManager.fileExists(atPath: rawPath) else {
            throw WorkspaceConfigParseError.invalidWorkspaceGuestPath(path: rawPath)
        }
        let resolved = launchDirectory.resolvingSymlinksInPath().path
        return try WorkspaceExcludePlanner.normalizedWorkspaceGuestPath(resolved)
    }

    private func isProtectedGuestPath(_ path: String, prefixes: [String]) -> Bool {
        for rawPrefix in prefixes {
            let normalized = rawPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, normalized.hasPrefix("/") else {
                continue
            }
            if path == normalized || path.hasPrefix(normalized + "/") {
                return true
            }
        }
        return false
    }
}

enum WorkspaceConfigParser {
    static func parse(_ raw: String) throws -> WorkspaceConfig {
        var currentSection = ""
        var excludes: [String] = []

        for line in raw.split(whereSeparator: \.isNewline) {
            let cleaned = stripTomlComment(from: String(line)).trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty {
                continue
            }
            if cleaned.hasPrefix("[") && cleaned.hasSuffix("]") {
                currentSection = String(cleaned.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }

            guard let eq = cleaned.firstIndex(of: "=") else {
                continue
            }
            let key = cleaned[..<eq].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = cleaned[cleaned.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)

            if currentSection == "workspace.excludes", key == "paths" {
                excludes = try parseStringArray(value)
                continue
            }
        }

        let validated = try excludes.map(validateExcludeRelativePath(_:))
        return WorkspaceConfig(excludes: validated)
    }

    static func validateExcludeRelativePath(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw WorkspaceConfigParseError.invalidExcludePath(path: raw, reason: "path must not be empty")
        }
        if trimmed.hasPrefix("/") {
            throw WorkspaceConfigParseError.invalidExcludePath(path: raw, reason: "absolute paths are not allowed")
        }
        if trimmed.hasPrefix("~") {
            throw WorkspaceConfigParseError.invalidExcludePath(path: raw, reason: "home-expansion paths are not allowed")
        }
        if trimmed.contains("\u{0000}") {
            throw WorkspaceConfigParseError.invalidExcludePath(path: raw, reason: "NUL is not allowed")
        }

        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        if parts.contains(where: { $0.isEmpty }) {
            throw WorkspaceConfigParseError.invalidExcludePath(path: raw, reason: "empty path segment is not allowed")
        }
        for p in parts {
            if p == "." || p == ".." {
                throw WorkspaceConfigParseError.invalidExcludePath(path: raw, reason: "dot traversal is not allowed")
            }
        }
        return parts.map(String.init).joined(separator: "/")
    }

    private static func parseStringArray(_ raw: String) throws -> [String] {
        guard raw.hasPrefix("["), raw.hasSuffix("]") else {
            throw WorkspaceConfigParseError.invalidToml(message: "paths must be a string array")
        }
        let data = Data(raw.utf8)
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let array = object as? [String] else {
            throw WorkspaceConfigParseError.invalidToml(message: "paths must be a string array")
        }
        return array
    }

    private static func stripTomlComment(from line: String) -> String {
        var inString = false
        var escaped = false
        var output = ""
        for ch in line {
            if escaped {
                output.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" {
                output.append(ch)
                escaped = inString
                continue
            }
            if ch == "\"" {
                inString.toggle()
                output.append(ch)
                continue
            }
            if ch == "#", !inString {
                break
            }
            output.append(ch)
        }
        return output
    }
}
