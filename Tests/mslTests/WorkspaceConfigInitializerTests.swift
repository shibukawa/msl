import XCTest
@testable import mslCore

final class WorkspaceConfigInitializerTests: XCTestCase {
    func testCreateConfigWritesTemplate() throws {
        let ctx = try WorkspaceConfigContext.make()
        defer { ctx.cleanup() }

        let initializer = WorkspaceConfigInitializer(fileManager: .default)
        let result = try initializer.createConfig(in: ctx.workspace, force: false)

        XCTAssertFalse(result.overwritten)
        XCTAssertEqual(result.configFile.path, ctx.workspace.appendingPathComponent(".mslconfig").path)
        let content = try String(contentsOf: result.configFile, encoding: .utf8)
        XCTAssertTrue(content.contains("[workspace.excludes]"))
        XCTAssertTrue(content.contains("node_modules"))
    }

    func testCreateConfigFailsWhenAlreadyExistsWithoutForce() throws {
        let ctx = try WorkspaceConfigContext.make()
        defer { ctx.cleanup() }

        let configFile = ctx.workspace.appendingPathComponent(".mslconfig", isDirectory: false)
        try Data("old\n".utf8).write(to: configFile, options: .atomic)

        let initializer = WorkspaceConfigInitializer(fileManager: .default)
        XCTAssertThrowsError(
            try initializer.createConfig(in: ctx.workspace, force: false)
        ) { error in
            guard let runtime = error as? MSLRuntimeError else {
                XCTFail("unexpected error: \(error)")
                return
            }
            XCTAssertTrue(runtime.message.contains(".mslconfig already exists"))
        }
    }

    func testCreateConfigOverwritesWhenForceEnabled() throws {
        let ctx = try WorkspaceConfigContext.make()
        defer { ctx.cleanup() }

        let configFile = ctx.workspace.appendingPathComponent(".mslconfig", isDirectory: false)
        try Data("old\n".utf8).write(to: configFile, options: .atomic)

        let initializer = WorkspaceConfigInitializer(fileManager: .default)
        let result = try initializer.createConfig(in: ctx.workspace, force: true)

        XCTAssertTrue(result.overwritten)
        let content = try String(contentsOf: configFile, encoding: .utf8)
        XCTAssertTrue(content.contains("[workspace.excludes]"))
        XCTAssertFalse(content.hasPrefix("old"))
    }

    func testCreateConfigWritesVSCodeSettingsWhenEditorSelected() throws {
        let ctx = try WorkspaceConfigContext.make()
        defer { ctx.cleanup() }

        let initializer = WorkspaceConfigInitializer(
            fileManager: .default,
            prompt: { _, defaultValue in defaultValue },
            detectionProvider: { WorkspaceEditorInstallState(vscodeInstalled: true, zedInstalled: false) }
        )
        let result = try initializer.createConfig(
            in: ctx.workspace,
            force: false,
            editorContext: WorkspaceEditorBootstrapContext(
                requestedEditors: [.vscode],
                assumeYes: false,
                interactive: false,
                sharedSSHConfigPath: "/tmp/msl-ssh-config",
                sshInfo: nil,
                workspaceGuestPath: nil
            )
        )

        XCTAssertTrue(result.vscodeUpdated)
        let settingsFile = ctx.workspace.appendingPathComponent(".vscode/settings.json", isDirectory: false)
        let content = try String(contentsOf: settingsFile, encoding: .utf8)
        XCTAssertTrue(content.contains("\"remote.SSH.configFile\""))
        XCTAssertTrue(content.contains("msl-ssh-config"))
    }

    func testCreateConfigMergesVSCodeSettings() throws {
        let ctx = try WorkspaceConfigContext.make()
        defer { ctx.cleanup() }

        let vscodeDir = ctx.workspace.appendingPathComponent(".vscode", isDirectory: true)
        try FileManager.default.createDirectory(at: vscodeDir, withIntermediateDirectories: true)
        let settingsFile = vscodeDir.appendingPathComponent("settings.json", isDirectory: false)
        try Data("""
        {
          "editor.tabSize": 2
        }
        """.utf8).write(to: settingsFile, options: .atomic)

        let initializer = WorkspaceConfigInitializer(
            fileManager: .default,
            prompt: { _, defaultValue in defaultValue },
            detectionProvider: { WorkspaceEditorInstallState(vscodeInstalled: true, zedInstalled: false) }
        )
        _ = try initializer.createConfig(
            in: ctx.workspace,
            force: false,
            editorContext: WorkspaceEditorBootstrapContext(
                requestedEditors: [.vscode],
                assumeYes: false,
                interactive: false,
                sharedSSHConfigPath: "/tmp/msl-ssh-config",
                sshInfo: nil,
                workspaceGuestPath: nil
            )
        )

        let content = try String(contentsOf: settingsFile, encoding: .utf8)
        XCTAssertTrue(content.contains("\"editor.tabSize\""))
        XCTAssertTrue(content.contains("\"remote.SSH.configFile\""))
    }

    func testCreateConfigSkipsVSCodeConflictWithoutPrompt() throws {
        let ctx = try WorkspaceConfigContext.make()
        defer { ctx.cleanup() }

        let vscodeDir = ctx.workspace.appendingPathComponent(".vscode", isDirectory: true)
        try FileManager.default.createDirectory(at: vscodeDir, withIntermediateDirectories: true)
        let settingsFile = vscodeDir.appendingPathComponent("settings.json", isDirectory: false)
        try Data("""
        {
          "remote.SSH.configFile": "/tmp/existing"
        }
        """.utf8).write(to: settingsFile, options: .atomic)

        let initializer = WorkspaceConfigInitializer(
            fileManager: .default,
            prompt: { _, _ in XCTFail("prompt should not be called"); return false },
            detectionProvider: { WorkspaceEditorInstallState(vscodeInstalled: true, zedInstalled: false) }
        )
        let result = try initializer.createConfig(
            in: ctx.workspace,
            force: false,
            editorContext: WorkspaceEditorBootstrapContext(
                requestedEditors: [.vscode],
                assumeYes: true,
                interactive: true,
                sharedSSHConfigPath: "/tmp/msl-ssh-config",
                sshInfo: nil,
                workspaceGuestPath: nil
            )
        )

        XCTAssertFalse(result.vscodeUpdated)
        XCTAssertTrue(result.notes.contains { $0.contains("existing remote.SSH.configFile differs") })
        let content = try String(contentsOf: settingsFile, encoding: .utf8)
        XCTAssertTrue(content.contains("/tmp/existing"))
    }

    func testInteractiveDefaultsUseDetectedEditors() throws {
        let ctx = try WorkspaceConfigContext.make()
        defer { ctx.cleanup() }

        var prompts: [(String, Bool)] = []
        let initializer = WorkspaceConfigInitializer(
            fileManager: .default,
            prompt: { message, defaultValue in
                prompts.append((message, defaultValue))
                return false
            },
            detectionProvider: { WorkspaceEditorInstallState(vscodeInstalled: true, zedInstalled: false) }
        )
        _ = try initializer.createConfig(
            in: ctx.workspace,
            force: false,
            editorContext: WorkspaceEditorBootstrapContext(
                requestedEditors: nil,
                assumeYes: false,
                interactive: true,
                sharedSSHConfigPath: "/tmp/msl-ssh-config",
                sshInfo: nil,
                workspaceGuestPath: nil
            )
        )

        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(prompts[0].1, true)
    }

    func testCreateConfigSkipsZedBootstrapWhenRequested() throws {
        let ctx = try WorkspaceConfigContext.make()
        defer { ctx.cleanup() }

        let sshInfo = LocalhostSSHInfo(
            instanceName: "ubuntu",
            alias: "msl-ubuntu",
            host: "127.0.0.1",
            port: 2222,
            user: "alice",
            sharedConfigPath: "/tmp/msl-shared-ssh-config",
            configPath: "/tmp/msl-instance-ssh-config",
            identityFile: "/tmp/id_ed25519",
            knownHostsFile: "/tmp/known_hosts"
        )
        let initializer = WorkspaceConfigInitializer(
            fileManager: .default,
            prompt: { _, defaultValue in defaultValue },
            detectionProvider: { WorkspaceEditorInstallState(vscodeInstalled: false, zedInstalled: true) }
        )
        let result = try initializer.createConfig(
            in: ctx.workspace,
            force: false,
            editorContext: WorkspaceEditorBootstrapContext(
                requestedEditors: [.zed],
                assumeYes: false,
                interactive: false,
                sharedSSHConfigPath: sshInfo.sharedConfigPath,
                sshInfo: sshInfo,
                workspaceGuestPath: "/mnt/macos/workspace"
            )
        )

        let settingsFile = ctx.workspace.appendingPathComponent(".zed/settings.json", isDirectory: false)
        XCTAssertFalse(result.zedUpdated)
        XCTAssertNil(result.zedSettingsFile)
        XCTAssertNil(result.zedSnippet)
        XCTAssertNil(result.zedOpenCommand)
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsFile.path))
        XCTAssertTrue(result.notes.contains { $0.contains("Zed workspace bootstrap is temporarily disabled") })
    }
}

private struct WorkspaceConfigContext {
    let root: URL
    let workspace: URL

    static func make() throws -> WorkspaceConfigContext {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-workspace-config-tests-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return WorkspaceConfigContext(root: root, workspace: workspace)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
