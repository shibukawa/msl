import Foundation
import Darwin

public struct WorkspaceConfigInitResult: Equatable {
    public let configFile: URL
    public let overwritten: Bool
    public let vscodeSettingsFile: URL?
    public let vscodeUpdated: Bool
    public let zedSettingsFile: URL?
    public let zedUpdated: Bool
    public let zedSnippet: String?
    public let zedOpenCommand: String?
    public let notes: [String]
}

public enum WorkspaceEditor: String, CaseIterable, Hashable {
    case vscode
    case zed
}

struct WorkspaceEditorInstallState: Equatable {
    var vscodeInstalled: Bool
    var zedInstalled: Bool

    func isInstalled(_ editor: WorkspaceEditor) -> Bool {
        switch editor {
        case .vscode:
            return vscodeInstalled
        case .zed:
            return zedInstalled
        }
    }
}

struct WorkspaceEditorBootstrapContext {
    var requestedEditors: Set<WorkspaceEditor>?
    var assumeYes: Bool
    var interactive: Bool
    var sharedSSHConfigPath: String
    var sshInfo: LocalhostSSHInfo?
    var workspaceGuestPath: String?
}

struct WorkspaceConfigInitializer {
    typealias PromptHandler = (_ prompt: String, _ defaultValue: Bool) -> Bool

    private let fileManager: FileManager
    private let process: ProcessExecutor
    private let prompt: PromptHandler
    private let detectionProvider: (() -> WorkspaceEditorInstallState)?

    init(
        fileManager: FileManager = .default,
        process: ProcessExecutor = ProcessExecutor(),
        prompt: PromptHandler? = nil,
        detectionProvider: (() -> WorkspaceEditorInstallState)? = nil
    ) {
        self.fileManager = fileManager
        self.process = process
        self.prompt = prompt ?? Self.defaultPrompt
        self.detectionProvider = detectionProvider
    }

    func createConfig(
        in directory: URL,
        force: Bool,
        editorContext: WorkspaceEditorBootstrapContext? = nil
    ) throws -> WorkspaceConfigInitResult {
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

        var vscodeSettingsFile: URL?
        var vscodeUpdated = false
        let zedSettingsFile: URL? = nil
        let zedUpdated = false
        let zedSnippet: String? = nil
        let zedOpenCommand: String? = nil
        var notes: [String] = []

        if let editorContext {
            let detection = detectInstalledEditors()
            let selectedEditors = chooseEditors(context: editorContext, detection: detection)
            if selectedEditors.contains(.vscode) {
                let result = try updateVSCodeSettings(
                    in: directory,
                    sharedSSHConfigPath: editorContext.sharedSSHConfigPath,
                    interactive: editorContext.interactive && !editorContext.assumeYes
                )
                vscodeSettingsFile = result.file
                vscodeUpdated = result.updated
                notes.append(contentsOf: result.notes)
            }
            if selectedEditors.contains(.zed) {
                notes.append("note: Zed workspace bootstrap is temporarily disabled; skipping Zed configuration.")
            }
        }

        return WorkspaceConfigInitResult(
            configFile: configFile,
            overwritten: alreadyExists,
            vscodeSettingsFile: vscodeSettingsFile,
            vscodeUpdated: vscodeUpdated,
            zedSettingsFile: zedSettingsFile,
            zedUpdated: zedUpdated,
            zedSnippet: zedSnippet,
            zedOpenCommand: zedOpenCommand,
            notes: notes
        )
    }

    func detectInstalledEditors() -> WorkspaceEditorInstallState {
        if let detectionProvider {
            return detectionProvider()
        }
        let vscodeInstalled = process.findExecutable(["code"]) != nil
            || fileManager.fileExists(atPath: "/Applications/Visual Studio Code.app")
            || fileManager.fileExists(atPath: fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Visual Studio Code.app").path)
        let zedInstalled = process.findExecutable(["zed"]) != nil
            || fileManager.fileExists(atPath: "/Applications/Zed.app")
            || fileManager.fileExists(atPath: fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Zed.app").path)
        return WorkspaceEditorInstallState(vscodeInstalled: vscodeInstalled, zedInstalled: zedInstalled)
    }

    private func chooseEditors(
        context: WorkspaceEditorBootstrapContext,
        detection: WorkspaceEditorInstallState
    ) -> Set<WorkspaceEditor> {
        if let requested = context.requestedEditors {
            return requested
        }
        if !context.interactive && !context.assumeYes {
            return []
        }
        return Set(WorkspaceEditor.allCases.filter { editor in
            if editor == .zed {
                return false
            }
            let defaultValue = detection.isInstalled(editor)
            if context.assumeYes {
                return defaultValue
            }
            let label = editor == .vscode ? "Configure VSCode workspace settings?" : "Configure Zed workspace settings?"
            return prompt(label, defaultValue)
        })
    }

    private func updateVSCodeSettings(
        in directory: URL,
        sharedSSHConfigPath: String,
        interactive: Bool
    ) throws -> (file: URL, updated: Bool, notes: [String]) {
        let vscodeDir = directory.appendingPathComponent(".vscode", isDirectory: true)
        let settingsFile = vscodeDir.appendingPathComponent("settings.json", isDirectory: false)
        let desiredValue = sharedSSHConfigPath
        try fileManager.createDirectory(at: vscodeDir, withIntermediateDirectories: true)

        guard fileManager.fileExists(atPath: settingsFile.path) else {
            let content = try Self.prettyPrintedJSON(["remote.SSH.configFile": desiredValue])
            try content.write(to: settingsFile, atomically: true, encoding: .utf8)
            return (settingsFile, true, [])
        }

        let raw = try String(contentsOf: settingsFile, encoding: .utf8)
        guard let data = raw.data(using: .utf8) else {
            return (settingsFile, false, ["warning: could not decode existing VSCode settings file; skipped update."])
        }
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []),
              var object = json as? [String: Any] else {
            if interactive, prompt("Replace invalid .vscode/settings.json with an object containing remote.SSH.configFile?", false) {
                let content = try Self.prettyPrintedJSON(["remote.SSH.configFile": desiredValue])
                try content.write(to: settingsFile, atomically: true, encoding: .utf8)
                return (settingsFile, true, [])
            }
            return (settingsFile, false, ["warning: existing .vscode/settings.json is not a JSON object; skipped update."])
        }

        if let existing = object["remote.SSH.configFile"] as? String, existing != desiredValue {
            if interactive, prompt("Overwrite existing remote.SSH.configFile in .vscode/settings.json?", false) {
                object["remote.SSH.configFile"] = desiredValue
            } else {
                return (settingsFile, false, ["warning: existing remote.SSH.configFile differs; skipped update."])
            }
        } else {
            object["remote.SSH.configFile"] = desiredValue
        }

        let content = try Self.prettyPrintedJSON(object)
        try content.write(to: settingsFile, atomically: true, encoding: .utf8)
        return (settingsFile, true, [])
    }

    private func updateZedSettings(
        in directory: URL,
        sshInfo: LocalhostSSHInfo?,
        workspaceGuestPath: String?,
        interactive: Bool
    ) throws -> (file: URL, updated: Bool, notes: [String]) {
        guard let sshInfo else {
            return (directory.appendingPathComponent(".zed/settings.json", isDirectory: false), false, [
                "warning: Zed setup was skipped because SSH info is unavailable for the target instance."
            ])
        }

        let zedDir = directory.appendingPathComponent(".zed", isDirectory: true)
        let settingsFile = zedDir.appendingPathComponent("settings.json", isDirectory: false)
        try fileManager.createDirectory(at: zedDir, withIntermediateDirectories: true)

        let guestPath = workspaceGuestPath ?? "~"
        var notes: [String] = []
        if workspaceGuestPath == nil {
            notes.append("warning: current workspace is outside the configured host share root; Zed example uses '~' instead of the current folder.")
        }

        let desiredConnection = makeZedConnectionObject(sshInfo: sshInfo, guestPath: guestPath)
        guard fileManager.fileExists(atPath: settingsFile.path) else {
            let content = try Self.prettyPrintedJSON(["ssh_connections": [desiredConnection]])
            try content.write(to: settingsFile, atomically: true, encoding: .utf8)
            return (settingsFile, true, notes)
        }

        let raw = try String(contentsOf: settingsFile, encoding: .utf8)
        guard let data = raw.data(using: .utf8) else {
            return (settingsFile, false, notes + ["warning: could not decode existing .zed/settings.json; skipped update."])
        }
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []),
              var object = json as? [String: Any] else {
            if interactive, prompt("Replace invalid .zed/settings.json with an object containing ssh_connections?", false) {
                let content = try Self.prettyPrintedJSON(["ssh_connections": [desiredConnection]])
                try content.write(to: settingsFile, atomically: true, encoding: .utf8)
                return (settingsFile, true, notes)
            }
            return (settingsFile, false, notes + ["warning: existing .zed/settings.json is not a JSON object; skipped update."])
        }

        var connections = object["ssh_connections"] as? [[String: Any]] ?? []
        if object["ssh_connections"] != nil && !(object["ssh_connections"] is [[String: Any]]) {
            if interactive, prompt("Replace non-array ssh_connections in .zed/settings.json?", false) {
                connections = []
            } else {
                return (settingsFile, false, notes + ["warning: existing ssh_connections in .zed/settings.json is not an array of objects; skipped update."])
            }
        }

        if let index = connections.firstIndex(where: { connection in
            let host = connection["host"] as? String
            let nickname = connection["nickname"] as? String
            return host == sshInfo.alias || nickname == sshInfo.alias
        }) {
            connections[index] = desiredConnection
        } else {
            connections.append(desiredConnection)
        }
        object["ssh_connections"] = connections

        let content = try Self.prettyPrintedJSON(object)
        try content.write(to: settingsFile, atomically: true, encoding: .utf8)
        return (settingsFile, true, notes)
    }

    private func makeZedOutput(
        sshInfo: LocalhostSSHInfo?,
        workspaceGuestPath: String?
    ) -> (snippet: String?, openCommand: String?, notes: [String]) {
        guard let sshInfo else {
            return (nil, nil, ["warning: Zed setup was skipped because SSH info is unavailable for the target instance."])
        }
        let guestPath = workspaceGuestPath ?? "~"
        var notes: [String] = []
        if workspaceGuestPath == nil {
            notes.append("warning: current workspace is outside the configured host share root; Zed example uses '~' instead of the current folder.")
        }
        let snippetObject: [String: Any] = ["ssh_connections": [makeZedConnectionObject(sshInfo: sshInfo, guestPath: guestPath)]]
        let snippet = (try? Self.prettyPrintedJSON(snippetObject)) ?? """
        {
          "ssh_connections": [
            {
              "args": ["-F", "\(sshInfo.sharedConfigPath)"],
              "host": "\(sshInfo.alias)",
              "nickname": "\(sshInfo.alias)",
              "port": \(sshInfo.port),
              "projects": [{ "paths": ["\(guestPath)"] }],
              "username": "\(sshInfo.user)"
            }
          ]
        }
        """
        let openCommand = "zed ssh://\(sshInfo.alias)\(guestPath)"
        return (snippet, openCommand, notes)
    }

    private func makeZedConnectionObject(sshInfo: LocalhostSSHInfo, guestPath: String) -> [String: Any] {
        [
            "args": ["-F", sshInfo.sharedConfigPath],
            "host": sshInfo.alias,
            "nickname": sshInfo.alias,
            "port": sshInfo.port,
            "projects": [
                ["paths": [guestPath]]
            ],
            "username": sshInfo.user
        ]
    }

    private static func prettyPrintedJSON(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func defaultPrompt(_ prompt: String, _ defaultValue: Bool) -> Bool {
        let suffix = defaultValue ? " [Y/n]: " : " [y/N]: "
        fputs("\(prompt)\(suffix)", stdout)
        fflush(stdout)
        guard let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !line.isEmpty else {
            return defaultValue
        }
        return line == "y" || line == "yes"
    }

    private static let defaultTemplate = """
# msl workspace configuration
# Presence of this file enables workspace mirror for this folder.
# Add guest-private exclusions (relative to this directory).

[workspace.excludes]
paths = ["node_modules"]
"""
}
