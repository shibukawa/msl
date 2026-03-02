import Foundation
import mslCore

func fail(_ message: String, code: Int32 = 1) -> Never {
    fputs("error: \(message)\n", stderr)
    Foundation.exit(code)
}

func parseCacheFetchArgs(_ raw: [String]) -> (targetAlias: String?, localFilePath: String?, force: Bool) {
    var i = 0
    var targetAlias: String?
    var localFilePath: String?
    var force = false

    while i < raw.count {
        let token = raw[i]
        switch token {
        case "--rootfs", "--file":
            guard i + 1 < raw.count else { fail("missing value for \(token)") }
            localFilePath = raw[i + 1]
            i += 2
        case "--force":
            force = true
            i += 1
        default:
            if token.hasPrefix("--") {
                fail("unknown option for cache fetch: \(token)")
            }
            if targetAlias != nil {
                fail("cache fetch accepts only one distro target")
            }
            targetAlias = token
            i += 1
        }
    }
    if targetAlias == nil && localFilePath == nil {
        fail("usage: msl cache fetch <distro> [--force] | msl cache fetch --rootfs <path> [--force]")
    }
    if targetAlias != nil && localFilePath != nil {
        fail("use either distro target or --rootfs, not both")
    }
    return (targetAlias, localFilePath, force)
}

func defaultInstallName(targetAlias: String?, localFilePath: String?) -> String {
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
    return "default"
}

func parseInstallArgs(_ raw: [String]) -> (
    name: String,
    targetAlias: String?,
    localFilePath: String?,
    rebuild: Bool,
    diskSizeGB: Int?
) {
    var i = 0
    var name: String?
    var targetAlias: String?
    var localFilePath: String?
    var rebuild = false
    var diskSizeGB: Int?

    while i < raw.count {
        let token = raw[i]
        switch token {
        case "--name":
            guard i + 1 < raw.count else { fail("missing value for --name") }
            name = raw[i + 1]
            i += 2
        case "--distro": // compatibility alias
            guard i + 1 < raw.count else { fail("missing value for \(token)") }
            targetAlias = raw[i + 1]
            i += 2
        case "--rootfs", "--file":
            guard i + 1 < raw.count else { fail("missing value for \(token)") }
            localFilePath = raw[i + 1]
            i += 2
        case "--rebuild":
            rebuild = true
            i += 1
        case "--disk-size-gb":
            guard i + 1 < raw.count else { fail("missing value for --disk-size-gb") }
            guard let value = Int(raw[i + 1]), value > 0 else {
                fail("--disk-size-gb must be a positive integer")
            }
            diskSizeGB = value
            i += 2
        default:
            if token.hasPrefix("--") {
                fail("unknown option for install: \(token)")
            }
            if targetAlias != nil {
                fail("install accepts only one distribution positional argument")
            }
            targetAlias = token
            i += 1
        }
    }

    if targetAlias == nil && localFilePath == nil {
        fail("install requires <distribution-name> or --rootfs <path>")
    }
    if targetAlias != nil && localFilePath != nil {
        fail("use either distribution-name or --rootfs, not both")
    }
    return (
        name ?? defaultInstallName(targetAlias: targetAlias, localFilePath: localFilePath),
        targetAlias,
        localFilePath,
        rebuild,
        diskSizeGB
    )
}

func parseUninstallArgs(_ raw: [String]) -> (name: String, keepCache: Bool) {
    var i = 0
    var keepCache = false
    var name: String?

    while i < raw.count {
        let token = raw[i]
        switch token {
        case "--keep-cache":
            keepCache = true
            i += 1
        default:
            if token.hasPrefix("--") {
                fail("unknown option for uninstall: \(token)")
            }
            if name != nil {
                fail("uninstall accepts only one instance name")
            }
            name = token
            i += 1
        }
    }

    guard let name else {
        fail("usage: msl uninstall <instance-name> [--keep-cache]")
    }
    return (name, keepCache)
}

func parseInitWorkspaceArgs(_ raw: [String]) -> Bool {
    var i = 0
    var force = false

    while i < raw.count {
        let token = raw[i]
        switch token {
        case "--force":
            force = true
            i += 1
        default:
            fail("unknown option for init workspace: \(token)")
        }
    }
    return force
}

func parseImageBuildArgs(_ raw: [String]) -> (profile: String, config: String, output: String, force: Bool) {
    var i = 0
    var profile = "default"
    var config: String?
    var output: String?
    var force = false

    while i < raw.count {
        let token = raw[i]
        switch token {
        case "--profile":
            guard i + 1 < raw.count else { fail("missing value for --profile") }
            profile = raw[i + 1]
            i += 2
        case "--config":
            guard i + 1 < raw.count else { fail("missing value for --config") }
            config = raw[i + 1]
            i += 2
        case "--output":
            guard i + 1 < raw.count else { fail("missing value for --output") }
            output = raw[i + 1]
            i += 2
        case "--force":
            force = true
            i += 1
        default:
            fail("unknown option for image build: \(token)")
        }
    }

    guard let config, !config.isEmpty else {
        fail("usage: msl image build --profile <name> --config <path> --output <path> [--force]")
    }
    guard let output, !output.isEmpty else {
        fail("usage: msl image build --profile <name> --config <path> --output <path> [--force]")
    }
    return (profile, config, output, force)
}

do {
    let parsed: MSLGlobalRuntimeOptions
    do {
        parsed = try MSLCLIOptionsParser.parseGlobalRuntimeOptions(Array(CommandLine.arguments.dropFirst()))
    } catch let error as MSLCLIParseError {
        fail(error.errorDescription ?? String(describing: error))
    }
    let instanceName = parsed.instanceName
    let args = parsed.remainingArguments
    let manager = try RuntimeManager(executablePath: CommandLine.arguments[0])

    if args.isEmpty {
        try manager.runDefaultShell(instanceName: instanceName)
    }

    if args.count == 1, args[0] == "--serial-console" {
        setenv("MSL_ATTACH_SERIAL", "1", 1)
        try manager.runDefaultShell(instanceName: instanceName)
    }

    if args.count == 1, args[0] == "--status" {
        try manager.printStatus()
        Foundation.exit(0)
    }

    if args.count == 1, args[0] == "--stop" {
        try manager.stopVM()
        Foundation.exit(0)
    }

    if args.count == 1, args[0] == "--list" {
        try manager.listInstalledInstances()
    }

    if args.count == 2, args[0] == "--set-default" {
        try manager.setDefaultInstance(name: args[1])
    }

    // --- msl --_daemon (internal: daemon process) ---
    if args.count == 1, args[0] == "--_daemon" {
        try manager.runDaemon(instanceName: instanceName)
    }

    // --- msl run [--timeout N] <cmd> [args...] ---
    if args.first == "run" {
        var timeoutSec = 0
        var runArgs = Array(args.dropFirst())
        if runArgs.count >= 2, runArgs[0] == "--timeout", let t = Int(runArgs[1]), t > 0 {
            timeoutSec = t
            runArgs = Array(runArgs.dropFirst(2))
        }
        if runArgs.isEmpty {
            fail("usage: msl run [--timeout N] <command> [args...]")
        }
        try manager.runCommand(argv: runArgs, timeoutSec: timeoutSec, instanceName: instanceName)
    }

    // --- msl cache fetch <distro> [--force]
    // --- msl cache fetch --rootfs <path> [--force]
    if args.count >= 2, args[0] == "cache" {
        let sub = args[1]
        if sub == "fetch" {
            let parsed = parseCacheFetchArgs(Array(args.dropFirst(2)))
            try manager.runCacheFetch(
                targetAlias: parsed.targetAlias,
                localFilePath: parsed.localFilePath,
                force: parsed.force
            )
        }
        if sub == "status" {
            try manager.runCacheSharingStatus()
        }
        fail("unsupported cache command. use: msl cache fetch <distro>|--rootfs <path> [--force] | msl cache status")
    }

    if args.count >= 2, args[0] == "init" {
        let sub = args[1]
        if sub == "workspace" {
            let force = parseInitWorkspaceArgs(Array(args.dropFirst(2)))
            try manager.runInitWorkspace(force: force)
        }
        fail("unsupported init command. use: msl init workspace [--force]")
    }

    if args.count >= 2, args[0] == "config" {
        let sub = args[1]
        if sub == "set" {
            if args.count != 4 {
                fail("usage: msl config set storageCacheToggles.<name> <true|false> | network.dns.mode <host|manual|unmanaged> | network.dns.manualNameservers <ip[,ip...]> | network.dns.manualSearchDomains <domain[,domain...]>")
            }
            try manager.runSetConfig(path: args[2], value: args[3])
        }

        if sub == "cache" {
            if args.count == 3, args[2] == "ls" {
                try manager.runListStorageCacheToggles()
            }
            fail("unsupported config cache command. use: msl config cache ls")
        }

        if sub == "cache-sharing" {
            if args.count == 3, args[2] == "ls" {
                try manager.runCacheSharingStatus()
            }
            fail("unsupported config cache-sharing command. use: msl config cache-sharing ls")
        }

        fail("unsupported config command. use: msl config set storageCacheToggles.<name> <true|false> | network.dns.mode <host|manual|unmanaged> | network.dns.manualNameservers <ip[,ip...]> | network.dns.manualSearchDomains <domain[,domain...]> | msl config cache ls | msl config cache-sharing ls")
    }

    if args.first == "memory" {
        if args.count == 1 || (args.count == 2 && args[1] == "status") {
            try manager.printMemoryStatus(instanceName: instanceName)
            Foundation.exit(0)
        }
        fail("unsupported memory command. use: msl memory [status]")
    }

    // --- msl install <distribution-name> [--name <instance>] [--rootfs <path>] [--rebuild] [--disk-size-gb <n>]
    if args.first == "install" {
        if args.count == 2, args[1] == "--list" {
            manager.listInstallableDistributions()
        }
        let parsed = parseInstallArgs(Array(args.dropFirst()))
        try manager.runInstall(
            name: parsed.name,
            targetAlias: parsed.targetAlias,
            localFilePath: parsed.localFilePath,
            rebuild: parsed.rebuild,
            diskSizeGB: parsed.diskSizeGB
        )
    }

    // --- msl _bootstrap-install ... (internal compatibility: legacy ext4 install path)
    if args.first == "_bootstrap-install" {
        let parsed = parseInstallArgs(Array(args.dropFirst()))
        try manager.runBootstrapInstall(
            name: parsed.name,
            targetAlias: parsed.targetAlias,
            localFilePath: parsed.localFilePath,
            rebuild: parsed.rebuild,
            diskSizeGB: parsed.diskSizeGB
        )
    }

    // --- msl uninstall <instance-name> [--keep-cache]
    if args.first == "uninstall" {
        let parsed = parseUninstallArgs(Array(args.dropFirst()))
        try manager.runUninstall(name: parsed.name, keepCache: parsed.keepCache)
    }

    // --- compatibility: msl image create --name <instance> (--distro <id> | --rootfs <path>) [--rebuild]
    if args.count >= 2, args[0] == "image" {
        let sub = args[1]
        if sub == "build" {
            let parsed = parseImageBuildArgs(Array(args.dropFirst(2)))
            try manager.runBuildStorageImage(
                profileName: parsed.profile,
                configPath: parsed.config,
                outputPath: parsed.output,
                force: parsed.force
            )
        }
        if sub == "create" {
            let parsed = parseInstallArgs(Array(args.dropFirst(2)))
            try manager.runBootstrapInstall(
                name: parsed.name,
                targetAlias: parsed.targetAlias,
                localFilePath: parsed.localFilePath,
                rebuild: parsed.rebuild,
                diskSizeGB: parsed.diskSizeGB
            )
        }
        fail("unsupported image command. use: msl image build --profile <name> --config <path> --output <path> [--force] | msl image create --name <instance> <distribution-name>|--rootfs <path> [--rebuild]")
    }

    if args.first == "port" {
        if args.count == 1 {
            try manager.listPortMappings()
            Foundation.exit(0)
        }
        let sub = args[1]
        if sub == "add", args.count == 3 {
            let mapping = String(args[2])
            try manager.addPortMapping(mapping)
            Foundation.exit(0)
        }
        if sub == "ls", args.count == 2 {
            try manager.listPortMappings()
            Foundation.exit(0)
        }
        if sub == "rm", args.count == 3 {
            let hostPortArg = String(args[2])
            try manager.removePortMapping(hostPortArg)
            Foundation.exit(0)
        }
        fail("unsupported port command. use: msl port [ls] | msl port add <hostPort>:<guestPort> | msl port rm <hostPort>")
    }

    if args.first == "network" {
        if args.count == 1 || (args.count == 2 && args[1] == "status") {
            try manager.printNetworkDNSStatus(instanceName: instanceName)
            Foundation.exit(0)
        }
        if args.count == 2, args[1] == "reconcile" {
            try manager.runNetworkDNSReconcile(instanceName: instanceName)
            Foundation.exit(0)
        }
        fail("unsupported network command. use: msl network [status] | msl network reconcile")
    }

    if args.count == 2, args[0] == "--_idle-expire", let deadline = Int64(args[1]) {
        try manager.handleIdleExpiry(deadlineEpochMs: deadline)
        Foundation.exit(0)
    }

    if args.count >= 2, args[0] == "--_init-exec" {
        var command: [String] = []
        for arg in args.dropFirst() {
            command.append(arg)
        }
        let exitCode = try manager.runInitExec(argv: command)
        Foundation.exit(exitCode)
    }

    fail("unsupported arguments. use: msl | msl --list | msl --set-default <name> | msl install ... | msl uninstall ... | msl run <cmd> | msl cache fetch ... | msl cache status | msl config set storageCacheToggles.<name> <true|false> | msl config cache ls | msl config cache-sharing ls | msl init workspace [--force] | msl memory [status] | msl network [status]|reconcile | msl --status | msl --stop | msl port [ls]|add|rm")
} catch let err as MSLRuntimeError {
    fail(err.message, code: err.exitCode)
} catch {
    fail(String(describing: error))
}
