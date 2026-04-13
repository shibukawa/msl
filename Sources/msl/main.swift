import ArgumentParser
import Foundation
import mslCore

func fail(_ message: String, code: Int32 = 1) -> Never {
    fputs("error: \(message)\n", stderr)
    Foundation.exit(code)
}

enum CLIInvocationContext {
    static var instanceName: String?
}

struct InstallInvocation {
    let name: String
    let targetAlias: String?
    let localFilePath: String?
    let rawDiskPath: String?
    let containerImageRef: String?
    let rebuild: Bool
    let diskSizeGB: Int?
}

func defaultInstallName(targetAlias: String?, localFilePath: String?, rawDiskPath: String?, containerImageRef: String?) -> String {
    if let targetAlias, !targetAlias.isEmpty {
        return targetAlias
    }
    if let localFilePath, !localFilePath.isEmpty {
        var name = URL(fileURLWithPath: localFilePath).deletingPathExtension().lastPathComponent
        if name.hasSuffix(".tar") {
            name = String(name.dropLast(4))
        }
        if name.isEmpty {
            return "local"
        }
        return name
    }
    if let rawDiskPath, !rawDiskPath.isEmpty {
        return URL(fileURLWithPath: rawDiskPath).deletingPathExtension().lastPathComponent
    }
    if let containerImageRef, !containerImageRef.isEmpty {
        let suffix = containerImageRef
            .replacingOccurrences(of: "://", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "@", with: "-")
        let compact = suffix
            .split(separator: "-")
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return compact.isEmpty ? "container" : compact
    }
    return "default"
}

func withRuntimeManager(_ action: (RuntimeManager) throws -> Void) {
    do {
        let manager = try RuntimeManager(executablePath: CommandLine.arguments[0])
        try action(manager)
    } catch let err as MSLRuntimeError {
        fail(err.message, code: err.exitCode)
    } catch {
        fail(String(describing: error))
    }
}

func handleInternalRuntimeFlags(_ parsed: MSLGlobalRuntimeOptions) -> Bool {
    let instanceName = parsed.instanceName
    let args = parsed.remainingArguments

    if args.count == 1, args[0] == "--_worker" {
        withRuntimeManager { manager in
            try manager.runWorker(instanceName: instanceName)
        }
        return true
    }

    if args.count == 1, args[0] == "--_daemon" {
        withRuntimeManager { manager in
            try manager.runWorker(instanceName: instanceName)
        }
        return true
    }

    if args.count == 2, args[0] == "--_idle-expire", let deadline = Int64(args[1]) {
        withRuntimeManager { manager in
            try manager.handleIdleExpiry(deadlineEpochMs: deadline)
        }
        return true
    }

    if args.count >= 2, args[0] == "--_init-exec" {
        withRuntimeManager { manager in
            let exitCode = try manager.runInitExec(argv: Array(args.dropFirst()))
            Foundation.exit(exitCode)
        }
        return true
    }

    return false
}

struct InstallOptions: ParsableArguments {
    @Option(name: [.customLong("name")], help: "Instance name to install.")
    var name: String?

    @Option(name: [.customLong("distro")], help: .hidden)
    var distroAlias: String?

    @Option(name: [.customLong("rootfs"), .customLong("file")], help: "Local rootfs archive path.")
    var localFilePath: String?

    @Option(name: [.customLong("raw")], help: "Local raw disk image path.")
    var rawDiskPath: String?

    @Option(name: [.customLong("from-container")], help: "Remote container image reference.")
    var containerImageRef: String?

    @Flag(name: [.customLong("rebuild")], help: "Force rebuild even if cached image exists.")
    var rebuild = false

    @Option(name: [.customLong("disk-size-gb")], help: "Disk size in GiB.")
    var diskSizeGB: Int?

    @Argument(help: "Distribution name.")
    var targetAlias: String?

    func resolve() throws -> InstallInvocation {
        if let diskSizeGB, diskSizeGB <= 0 {
            throw ValidationError("--disk-size-gb must be a positive integer")
        }

        let resolvedTarget = targetAlias ?? distroAlias
        if targetAlias != nil, distroAlias != nil {
            throw ValidationError("Use either positional <distribution-name> or --distro, not both")
        }
        let sourceCount = [resolvedTarget, localFilePath, rawDiskPath, containerImageRef].compactMap { $0 }.count
        if sourceCount == 0 {
            throw ValidationError("install requires <distribution-name>, --rootfs <path>, --raw <path>, or --from-container <image-ref>")
        }
        if sourceCount > 1 {
            throw ValidationError("Use only one of <distribution-name>, --rootfs/--file, --raw, or --from-container")
        }
        if rawDiskPath != nil, diskSizeGB != nil {
            throw ValidationError("--disk-size-gb cannot be used with --raw")
        }

        return InstallInvocation(
            name: name ?? defaultInstallName(
                targetAlias: resolvedTarget,
                localFilePath: localFilePath,
                rawDiskPath: rawDiskPath,
                containerImageRef: containerImageRef
            ),
            targetAlias: resolvedTarget,
            localFilePath: localFilePath,
            rawDiskPath: rawDiskPath,
            containerImageRef: containerImageRef,
            rebuild: rebuild,
            diskSizeGB: diskSizeGB
        )
    }
}

struct MSLCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "msl",
        abstract: "Mac Subsystem for Linux",
        discussion: "Run `msl <command> --help` for command details.",
        version: "dev",
        subcommands: [
            RunCommand.self,
            CpCommand.self,
            ListCommand.self,
            StatusCommand.self,
            StopCommand.self,
            InstallCommand.self,
            UninstallCommand.self,
            CacheCommand.self,
            ConfigCommand.self,
            InitCommand.self,
            MemoryCommand.self,
            NetworkCommand.self,
            PortCommand.self,
            SSHInfoCommand.self,
            BootstrapInstallCommand.self
        ]
    )

    @Option(name: [.short, .long], help: "Target instance name.")
    var instance: String?

    @Option(name: [.customLong("set-default")], help: "Set default instance name.")
    var setDefault: String?

    @Flag(name: [.customLong("serial-console")], help: "Attach through serial console for diagnostics.")
    var serialConsole = false

    mutating func validate() throws {
        CLIInvocationContext.instanceName = instance

        var modeCount = 0
        if setDefault != nil { modeCount += 1 }
        if serialConsole { modeCount += 1 }
        if modeCount > 1 {
            throw ValidationError("Use only one of --set-default or --serial-console")
        }
    }

    mutating func run() throws {
        withRuntimeManager { manager in
            if let setDefault {
                try manager.setDefaultInstance(name: setDefault)
            }
            if serialConsole {
                setenv("MSL_ATTACH_SERIAL", "1", 1)
            }
            try manager.runDefaultShell(instanceName: instance)
        }
    }
}

struct RunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a command in Linux.",
        discussion: "Examples:\n  msl run uname -a\n  msl run -t 5 uname -a"
    )

    @Option(name: [.short, .long], help: "Timeout in seconds.")
    var timeout: Int?

    @Argument(help: "Command and arguments.")
    var command: [String] = []

    mutating func validate() throws {
        if let timeout, timeout <= 0 {
            throw ValidationError("--timeout must be a positive integer")
        }
        if command.isEmpty {
            throw ValidationError("Missing command. See `msl run --help`.")
        }
    }

    mutating func run() throws {
        withRuntimeManager { manager in
            try manager.runCommand(
                argv: command,
                timeoutSec: timeout ?? 0,
                instanceName: CLIInvocationContext.instanceName
            )
        }
    }
}

struct CpCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cp",
        abstract: "Copy files between the host and an MSL instance.",
        discussion: """
        Use @:/path to reference the VM side.

        Examples:
          msl --instance dev cp local.txt @:/tmp/local.txt
          msl --instance dev cp @:/var/log/syslog ./syslog
          msl --instance dev cp -r ./dir @:/tmp/dir
        """
    )

    @Flag(name: [.short, .long], help: "Copy directories recursively.")
    var recursive = false

    @Argument(help: "Source path. Use @:/path for a VM path.")
    var src: String

    @Argument(help: "Destination path. Use @:/path for a VM path.")
    var dest: String

    mutating func validate() throws {
        do {
            _ = try MSLCopyPathParser.parseTransfer(src: src, dest: dest, recursive: recursive)
        } catch let error as MSLRuntimeError {
            throw ValidationError(error.message)
        }
    }

    mutating func run() throws {
        withRuntimeManager { manager in
            try manager.runCopy(
                src: src,
                dest: dest,
                recursive: recursive,
                instanceName: CLIInvocationContext.instanceName
            )
        }
    }
}

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List installed instances."
    )

    @Flag(name: [.long, .customLong("include-reserved")], help: "Include reserved internal instances.")
    var all = false

    mutating func run() throws {
        withRuntimeManager { manager in
            try manager.listInstalledInstances(includeReserved: all)
        }
    }
}

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show runtime status."
    )

    @Flag(name: [.short, .long], help: "Show all instances.")
    var all = false

    @Argument(help: "Instance name.")
    var instance: String?

    mutating func validate() throws {
        if all, instance != nil {
            throw ValidationError("`--all` cannot be combined with an instance argument")
        }
        if instance != nil, CLIInvocationContext.instanceName != nil {
            throw ValidationError("Specify target instance with either global `--instance`/`-i` or `status <instance>`, not both")
        }
    }

    mutating func run() throws {
        let targetInstance = instance ?? CLIInvocationContext.instanceName
        withRuntimeManager { manager in
            try manager.printStatus(instanceName: targetInstance, all: all)
        }
    }
}

struct StopCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop runtime."
    )

    @Flag(name: [.customLong("app")], help: "Stop the desktop app manager.")
    var app = false

    @Flag(name: [.short, .long], help: "Stop all running instances.")
    var all = false

    @Argument(help: "Instance name.")
    var instance: String?

    mutating func validate() throws {
        if all, instance != nil {
            throw ValidationError("`--all` cannot be combined with an instance argument")
        }
        if instance != nil, CLIInvocationContext.instanceName != nil {
            throw ValidationError("Specify target instance with either global `--instance`/`-i` or `stop <instance>`, not both")
        }
        let targetInstance = instance ?? CLIInvocationContext.instanceName
        if app, targetInstance != nil {
            throw ValidationError("`stop --app` cannot be combined with an instance argument")
        }
    }

    mutating func run() throws {
        let targetInstance = instance ?? CLIInvocationContext.instanceName
        withRuntimeManager { manager in
            if app {
                try manager.stopAppManager()
                return
            }
            try manager.stopVM(instanceName: targetInstance, all: all)
            if all {
                try manager.stopAppManager()
            }
        }
    }
}

struct InstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install an instance from distro, rootfs, or raw disk."
    )

    @Flag(name: [.customLong("list")], help: "List installable distributions.")
    var list = false

    @OptionGroup
    var options: InstallOptions

    mutating func validate() throws {
        if list {
            if options.name != nil ||
                options.distroAlias != nil ||
                options.localFilePath != nil ||
                options.rebuild ||
                options.diskSizeGB != nil ||
                options.targetAlias != nil {
                throw ValidationError("--list does not accept install arguments")
            }
            return
        }
        _ = try options.resolve()
    }

    mutating func run() throws {
        withRuntimeManager { manager in
            if list {
                manager.listInstallableDistributions()
            }
            let invocation = try options.resolve()
            try manager.runInstall(
                name: invocation.name,
                targetAlias: invocation.targetAlias,
                localFilePath: invocation.localFilePath,
                rawDiskPath: invocation.rawDiskPath,
                containerImageRef: invocation.containerImageRef,
                rebuild: invocation.rebuild,
                diskSizeGB: invocation.diskSizeGB
            )
        }
    }
}

struct BootstrapInstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "_bootstrap-install",
        abstract: "Internal bootstrap installer.",
        shouldDisplay: false
    )

    @OptionGroup
    var options: InstallOptions

    mutating func validate() throws {
        let invocation = try options.resolve()
        if invocation.rawDiskPath != nil {
            throw ValidationError("_bootstrap-install does not support --raw")
        }
    }

    mutating func run() throws {
        withRuntimeManager { manager in
            let invocation = try options.resolve()
            try manager.runBootstrapInstall(
                name: invocation.name,
                targetAlias: invocation.targetAlias,
                localFilePath: invocation.localFilePath,
                rebuild: invocation.rebuild,
                diskSizeGB: invocation.diskSizeGB
            )
        }
    }
}

struct UninstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Uninstall an instance."
    )

    @Flag(name: [.customLong("keep-cache")], help: "Keep shared cache after uninstall.")
    var keepCache = false

    @Argument(help: "Instance name.")
    var name: String

    mutating func run() throws {
        withRuntimeManager { manager in
            try manager.runUninstall(name: name, keepCache: keepCache)
        }
    }
}

struct CacheCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cache",
        abstract: "Cache operations.",
        subcommands: [CacheFetchCommand.self, CacheStatusCommand.self]
    )
}

struct CacheFetchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fetch",
        abstract: "Fetch cache entry from distro or local rootfs."
    )

    @Argument(help: "Distribution alias.")
    var targetAlias: String?

    @Option(name: [.customLong("rootfs"), .customLong("file")], help: "Local rootfs archive path.")
    var localFilePath: String?

    @Flag(name: [.customLong("force")], help: "Force refresh.")
    var force = false

    mutating func validate() throws {
        if targetAlias == nil, localFilePath == nil {
            throw ValidationError("cache fetch requires <distro> or --rootfs <path>")
        }
        if targetAlias != nil, localFilePath != nil {
            throw ValidationError("Use either distro target or --rootfs, not both")
        }
    }

    mutating func run() throws {
        withRuntimeManager { manager in
            try manager.runCacheFetch(
                targetAlias: targetAlias,
                localFilePath: localFilePath,
                force: force
            )
        }
    }
}

struct CacheStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show cache sharing status."
    )

    mutating func run() throws {
        withRuntimeManager { manager in
            try manager.runCacheSharingStatus()
        }
    }
}

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Configuration operations.",
        subcommands: [ConfigSetCommand.self, ConfigCacheCommand.self, ConfigCacheSharingCommand.self]
    )
}

struct ConfigSetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set configuration value."
    )

    @Argument(help: "Config path.")
    var path: String

    @Argument(help: "Config value.")
    var value: String

    mutating func run() throws {
        withRuntimeManager { manager in
            try manager.runSetConfig(path: path, value: value)
        }
    }
}

struct ConfigCacheCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cache",
        abstract: "Storage cache toggles.",
        subcommands: [ConfigCacheLsCommand.self]
    )
}

struct ConfigCacheLsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List storage cache toggles.")

    mutating func run() throws {
        withRuntimeManager { manager in
            try manager.runListStorageCacheToggles()
        }
    }
}

struct ConfigCacheSharingCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cache-sharing",
        abstract: "Cache sharing status.",
        subcommands: [ConfigCacheSharingLsCommand.self]
    )
}

struct ConfigCacheSharingLsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List cache sharing status.")

    mutating func run() throws {
        withRuntimeManager { manager in
            try manager.runCacheSharingStatus()
        }
    }
}

struct InitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Initialization helpers.",
        subcommands: [InitWorkspaceCommand.self]
    )
}

struct InitWorkspaceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workspace",
        abstract: "Initialize workspace config."
    )

    @Flag(name: [.customLong("force")], help: "Overwrite existing workspace config.")
    var force = false

    mutating func run() throws {
        withRuntimeManager { manager in
            try manager.runInitWorkspace(force: force, instanceName: CLIInvocationContext.instanceName)
        }
    }
}

struct MemoryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "memory",
        abstract: "Memory operations.",
        subcommands: [MemoryStatusCommand.self],
        defaultSubcommand: MemoryStatusCommand.self
    )
}

struct MemoryStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show memory status.")

    mutating func run() throws {
        withRuntimeManager { manager in
            try manager.printMemoryStatus(instanceName: CLIInvocationContext.instanceName)
        }
    }
}

struct NetworkCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "network",
        abstract: "Network operations.",
        subcommands: [NetworkStatusCommand.self, NetworkReconcileCommand.self],
        defaultSubcommand: NetworkStatusCommand.self
    )
}

struct NetworkStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show DNS/network status.")

    mutating func run() throws {
        withRuntimeManager { manager in
            try manager.printNetworkDNSStatus(instanceName: CLIInvocationContext.instanceName)
        }
    }
}

struct NetworkReconcileCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reconcile", abstract: "Reconcile DNS settings.")

    mutating func run() throws {
        withRuntimeManager { manager in
            try manager.runNetworkDNSReconcile(instanceName: CLIInvocationContext.instanceName)
        }
    }
}

struct PortCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "port",
        abstract: "Port forwarding operations.",
        subcommands: [PortLsCommand.self, PortAddCommand.self, PortRmCommand.self],
        defaultSubcommand: PortLsCommand.self
    )
}

struct PortLsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List port mappings.")

    mutating func run() throws {
        withRuntimeManager { manager in
            try manager.listPortMappings(instanceName: CLIInvocationContext.instanceName)
        }
    }
}

struct PortAddCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Add host:guest port mapping.")

    @Argument(help: "Mapping as <hostPort>:<guestPort>")
    var mapping: String

    mutating func run() throws {
        withRuntimeManager { manager in
            try manager.addPortMapping(mapping, instanceName: CLIInvocationContext.instanceName)
        }
    }
}

struct PortRmCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove mapping by host port.")

    @Argument(help: "Host port.")
    var hostPort: String

    mutating func run() throws {
        withRuntimeManager { manager in
            try manager.removePortMapping(hostPort, instanceName: CLIInvocationContext.instanceName)
        }
    }
}

struct SSHInfoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ssh-info",
        abstract: "Print SSH connection details for the localhost facade."
    )

    @Option(name: [.customLong("format")], help: "Output format: text or json.")
    var format = "text"

    mutating func validate() throws {
        let normalized = format.lowercased()
        if normalized != "text" && normalized != "json" {
            throw ValidationError("--format must be 'text' or 'json'")
        }
        format = normalized
    }

    mutating func run() throws {
        withRuntimeManager { manager in
            try manager.runSSHInfo(
                instanceName: CLIInvocationContext.instanceName,
                format: format
            )
        }
    }
}

func runMSLCLI() {
    let raw = Array(CommandLine.arguments.dropFirst())

    do {
        let globalParsed = try MSLCLIOptionsParser.parseGlobalRuntimeOptions(raw)
        CLIInvocationContext.instanceName = globalParsed.instanceName

        if handleInternalRuntimeFlags(globalParsed) {
            return
        }

        MSLCommand.main(raw)
    } catch let error as MSLCLIParseError {
        fail(error.errorDescription ?? String(describing: error))
    } catch {
        fail(String(describing: error))
    }
}

runMSLCLI()
