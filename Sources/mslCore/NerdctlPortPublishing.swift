import Foundation

enum NerdctlPortPublishing {
    static func directForwardMappings(from argv: [String], instanceName: String) -> [PortMapping] {
        guard let runIndex = runCommandIndex(in: argv) else {
            return []
        }

        var mappings: [PortMapping] = []
        var index = runIndex + 1
        while index < argv.count {
            let arg = argv[index]
            let spec: String?
            if arg == "-p" || arg == "--publish" {
                let nextIndex = index + 1
                spec = nextIndex < argv.count ? argv[nextIndex] : nil
                index += 2
            } else if arg.hasPrefix("--publish=") {
                spec = String(arg.dropFirst("--publish=".count))
                index += 1
            } else if arg.hasPrefix("-p"), arg.count > 2 {
                spec = String(arg.dropFirst(2))
                index += 1
            } else if runOptionsWithValues.contains(arg) {
                spec = nil
                index += 2
            } else if arg.hasPrefix("-") {
                spec = nil
                index += 1
            } else {
                break
            }

            guard let spec,
                  let mapping = directForwardMapping(fromPublishSpec: spec, instanceName: instanceName) else {
                continue
            }
            if !mappings.contains(where: { $0.hostPort == mapping.hostPort }) {
                mappings.append(mapping)
            }
        }
        return mappings
    }

    private static let globalOptionsWithValues: Set<String> = [
        "--address", "-a",
        "--namespace", "-n",
        "--host", "-H",
        "--snapshotter",
        "--data-root",
        "--cni-path",
        "--cni-netconfpath"
    ]

    private static let runOptionsWithValues: Set<String> = [
        "--add-host",
        "--dns",
        "--entrypoint",
        "--env", "-e",
        "--hostname", "-h",
        "--label", "-l",
        "--memory", "-m",
        "--mount",
        "--name",
        "--network",
        "--platform",
        "--pull",
        "--restart",
        "--user", "-u",
        "--volume", "-v",
        "--workdir", "-w"
    ]

    private static func runCommandIndex(in argv: [String]) -> Int? {
        var index = 0
        while index < argv.count {
            let token = argv[index]
            if token == "--" {
                return nil
            }
            if globalOptionsWithValues.contains(token) {
                index += 2
                continue
            }
            if token.hasPrefix("-") {
                index += 1
                continue
            }
            return token == "run" ? index : nil
        }
        return nil
    }

    private static func directForwardMapping(fromPublishSpec rawSpec: String, instanceName: String) -> PortMapping? {
        let spec = rawSpec.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rawSpec
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)

        let bindAddress: String
        let hostPortText: String
        switch parts.count {
        case 2:
            bindAddress = "127.0.0.1"
            hostPortText = parts[0]
        case 3:
            bindAddress = normalizedBindAddress(parts[0])
            hostPortText = parts[1]
        default:
            return nil
        }

        guard let hostPort = Int(hostPortText),
              (1...65_535).contains(hostPort) else {
            return nil
        }

        return PortMapping(
            hostPort: hostPort,
            guestPort: hostPort,
            bindAddress: bindAddress,
            instance: instanceName,
            source: "nerdctl"
        )
    }

    private static func normalizedBindAddress(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "127.0.0.1" : trimmed
    }
}
