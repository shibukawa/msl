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
    let rebuild: Bool
    let diskSizeGB: Int?
}

func defaultInstallName(targetAlias: String?, localFilePath: String?, rawDiskPath: String?) -> String {
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

    if args.count == 1, args[0] == "--_daemon" {
        withRuntimeManager { manager in
            try manager.runDaemon(instanceName: instanceName)
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
        let sourceCount = [resolvedTarget, localFilePath, rawDiskPath].compactMap { $0 }.count
        if sourceCount == 0 {
            throw ValidationError("install requires <distribution-name>, --rootfs <path>, or --raw <path>")
        }
        if sourceCount > 1 {
            throw ValidationError("Use only one of <distribution-name>, --rootfs/--file, or --raw")
        }
        if rawDiskPath != nil, diskSizeGB != nil {
            throw ValidationError("--disk-size-gb cannot be used with --raw")
        }

        return InstallInvocation(
            name: name ?? defaultInstallName(
                targetAlias: resolvedTarget,
                localFilePath: localFilePath,
                rawDiskPath: rawDiskPath
            ),
            targetAlias: resolvedTarget,
            localFilePath: localFilePath,
            rawDiskPath: rawDiskPath,
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
            ListCommand.self,
            StatusCommand.self,
            StopCommand.self,
            ImageCommand.self,
            InstallCommand.self,
            UninstallCommand.self,
            CacheCommand.self,
            ConfigCommand.self,
            InitCommand.self,
            MemoryCommand.self,
            NetworkCommand.self,
            PortCommand.self,
            BootstrapInstallCommand.self
        ]
    )

    @Option(name: [.customLong("set-default")], help: "Set default instance name.")
    var setDefault: String?

    @Flag(name: [.customLong("serial-console")], help: "Attach through serial console for diagnostics.")
    var serialConsole = false

    mutating func validate() throws {
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
            try manager.runDefaultShell(instanceName: CLIInvocationContext.instanceName)
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

    @Argument(parsing: .captureForPassthrough, help: "Command and arguments.")
    var command: [String] = []

    private var normalizedCommand: [String] {
        var argv = command
        while argv.first == "--" {
            argv.removeFirst()
        }
        return argv
    }

    mutating func validate() throws {
        if let timeout, timeout <= 0 {
            throw ValidationError("--timeout must be a positive integer")
        }
        if normalizedCommand.isEmpty {
            throw ValidationError("Missing command. See `msl run --help`.")
        }
    }

    mutating func run() throws {
        withRuntimeManager { manager in
            try manager.runCommand(
                argv: normalizedCommand,
                timeoutSec: timeout ?? 0,
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

    mutating func run() throws {
        withRuntimeManager { manager in
            try manager.listInstalledInstances()
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
    }

    mutating func run() throws {
        let targetInstance = instance ?? CLIInvocationContext.instanceName
        withRuntimeManager { manager in
            try manager.stopVM(instanceName: targetInstance, all: all)
        }
    }
}

struct ImageCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "image",
        abstract: "Image maintenance operations.",
        subcommands: [
            ImageInspectCommand.self,
            ImageScanCommand.self,
            ImageResizeCommand.self,
            ImageDefragCommand.self,
            ImageExportCommand.self
        ]
    )
}

struct ImageInspectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect", abstract: "Inspect image metadata and disk stats.")

    @Argument(help: "Instance name.")
    var instance: String?

    mutating func validate() throws {
        if instance != nil, CLIInvocationContext.instanceName != nil {
            throw ValidationError("Specify target instance with either global `--instance`/`-i` or `image inspect <instance>`, not both")
        }
    }

    mutating func run() throws {
        let targetInstance = instance ?? CLIInvocationContext.instanceName
        withRuntimeManager { manager in
            try manager.printImageInspect(instanceName: targetInstance)
        }
    }
}

struct ImageScanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Run vulnerability security scan.",
        subcommands: [
            ImageScanRunCommand.self,
            ImageScanResultCommand.self
        ],
        defaultSubcommand: ImageScanRunCommand.self
    )
}

struct ImageScanRunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "run", abstract: "Run vulnerability security scan.")

    @Argument(help: "Instance name.")
    var instance: String?

    @Option(name: [.customLong("policy")], help: "Policy mode: allow|warn|block")
    var policy: String = "warn"

    @Flag(name: [.customLong("offline")], help: "Use local cache only.")
    var offline = false

    @Flag(name: [.customLong("update-vuls")], help: "Force Vuls runtime update check.")
    var updateVuls = false

    @Option(name: [.customLong("output")], help: "Write output to file.")
    var output: String?

    mutating func validate() throws {
        if instance != nil, CLIInvocationContext.instanceName != nil {
            throw ValidationError("Specify target instance with either global `--instance`/`-i` or `image scan <instance>`, not both")
        }
        if offline, updateVuls {
            throw ValidationError("--offline and --update-vuls cannot be used together")
        }
        if let output, output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--output must not be empty")
        }
    }

    mutating func run() throws {
        let targetInstance = instance ?? CLIInvocationContext.instanceName
        withRuntimeManager { manager in
            try manager.runImageScan(
                instanceName: targetInstance,
                policyRaw: policy,
                offline: offline,
                updateVuls: updateVuls,
                outputPath: output
            )
        }
    }
}

struct ImageScanResultCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "result", abstract: "Show latest scan result for instance.")

    @Argument(help: "Instance name.")
    var instance: String?

    @Flag(name: [.customLong("http")], help: "Start vulsrepo server and open browser.")
    var http = false

    @Option(name: [.customLong("port")], help: "HTTP port for vulsrepo.")
    var port: Int = 5511

    mutating func validate() throws {
        if instance != nil, CLIInvocationContext.instanceName != nil {
            throw ValidationError("Specify target instance with either global `--instance`/`-i` or `image scan result <instance>`, not both")
        }
        if port <= 0 || port > 65535 {
            throw ValidationError("--port must be in 1..65535")
        }
    }

    mutating func run() throws {
        let targetInstance = instance ?? CLIInvocationContext.instanceName
        withRuntimeManager { manager in
            if http {
                try manager.runImageScanResultHTTP(instanceName: targetInstance, port: port)
            } else {
                try manager.runImageScanResultCLI(instanceName: targetInstance)
            }
        }
    }
}

struct ImageResizeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "resize", abstract: "Grow disk image size.")

    @Argument(help: "Usage: [<instance>] <size>. size supports M/MB/G/GB (e.g. 1536M, 1.5G).")
    var arguments: [String] = []

    private var resolvedInstance: String?
    private var resolvedSizeBytes: Int64 = 0

    mutating func validate() throws {
        guard arguments.count == 1 || arguments.count == 2 else {
            throw ValidationError("Usage: msl image resize [<instance>] <size>. size supports M/MB/G/GB (e.g. 1536M, 1.5G).")
        }
        if arguments.count == 2, CLIInvocationContext.instanceName != nil {
            throw ValidationError("Specify target instance with either global `--instance`/`-i` or `image resize <instance> <size>`, not both")
        }
        resolvedInstance = arguments.count == 2 ? arguments[0] : CLIInvocationContext.instanceName
        resolvedSizeBytes = try Self.parseResizeSize(arguments.last ?? "")
    }

    private static func parseResizeSize(_ raw: String) throws -> Int64 {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^([0-9]+(?:\.[0-9]+)?)\s*([mMgG](?:[bB])?)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            throw ValidationError("invalid size '\(raw)'. expected formats like 1536M or 1.5G")
        }
        let nsrange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, options: [], range: nsrange),
              match.numberOfRanges == 3,
              let numberRange = Range(match.range(at: 1), in: trimmed),
              let unitRange = Range(match.range(at: 2), in: trimmed) else {
            throw ValidationError("invalid size '\(raw)'. expected formats like 1536M or 1.5G")
        }
        guard let value = Double(trimmed[numberRange]), value > 0, value.isFinite else {
            throw ValidationError("invalid size '\(raw)'. size must be a positive number")
        }
        let unit = trimmed[unitRange].lowercased()
        let multiplier: Double = unit.hasPrefix("g") ? 1024 * 1024 * 1024 : 1024 * 1024
        let bytes = value * multiplier
        guard bytes.isFinite, bytes > 0, bytes <= Double(Int64.max) else {
            throw ValidationError("size is out of range: \(raw)")
        }
        return Int64(bytes.rounded(.up))
    }

    mutating func run() throws {
        withRuntimeManager { manager in
            try manager.runImageResize(instanceName: resolvedInstance, sizeBytes: resolvedSizeBytes)
        }
    }
}

struct ImageDefragCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "defrag", abstract: "Run guest filesystem trim (fstrim).")

    @Argument(help: "Instance name.")
    var instance: String?

    @Flag(name: [.customLong("dry-run")], help: "Show what would be done.")
    var dryRun = false

    mutating func validate() throws {
        if instance != nil, CLIInvocationContext.instanceName != nil {
            throw ValidationError("Specify target instance with either global `--instance`/`-i` or `image defrag <instance>`, not both")
        }
    }

    mutating func run() throws {
        let targetInstance = instance ?? CLIInvocationContext.instanceName
        withRuntimeManager { manager in
            try manager.runImageDefrag(instanceName: targetInstance, dryRun: dryRun)
        }
    }
}

struct ImageExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "export", abstract: "Export image artifacts.")

    enum ExportMode: String, ExpressibleByArgument {
        case archive
        case rootfs
    }

    @Argument(help: "Instance name.")
    var instance: String?

    @Option(name: [.customLong("mode")], help: "Export mode: archive|rootfs")
    var mode: ExportMode = .archive

    @Option(name: [.customLong("output")], help: "Output file path.")
    var output: String?

    @Flag(name: [.customLong("force")], help: "Overwrite output if exists.")
    var force = false

    mutating func validate() throws {
        if instance != nil, CLIInvocationContext.instanceName != nil {
            throw ValidationError("Specify target instance with either global `--instance`/`-i` or `image export <instance>`, not both")
        }
        if let output, output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--output must not be empty")
        }
    }

    mutating func run() throws {
        let targetInstance = instance ?? CLIInvocationContext.instanceName
        withRuntimeManager { manager in
            try manager.runImageExport(
                instanceName: targetInstance,
                mode: mode.rawValue,
                outputPath: output,
                force: force
            )
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
            try manager.runInitWorkspace(force: force)
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

func runMSLCLI() {
    let raw = Array(CommandLine.arguments.dropFirst())

    do {
        let globalParsed = try MSLCLIOptionsParser.parseGlobalRuntimeOptions(raw)
        CLIInvocationContext.instanceName = globalParsed.instanceName

        if handleInternalRuntimeFlags(globalParsed) {
            return
        }

        MSLCommand.main(globalParsed.remainingArguments)
    } catch let error as MSLCLIParseError {
        fail(error.errorDescription ?? String(describing: error))
    } catch {
        fail(String(describing: error))
    }
}

runMSLCLI()
