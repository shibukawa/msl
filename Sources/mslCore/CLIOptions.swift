import Foundation

public struct MSLGlobalRuntimeOptions: Equatable {
    public var instanceName: String?
    public var remainingArguments: [String]

    public init(instanceName: String?, remainingArguments: [String]) {
        self.instanceName = instanceName
        self.remainingArguments = remainingArguments
    }
}

public enum MSLCLIParseError: Error, LocalizedError, Equatable {
    case missingValue(option: String)
    case duplicateOption(option: String)
    case emptyValue(option: String)

    public var errorDescription: String? {
        switch self {
        case .missingValue(let option):
            return "missing value for \(option)"
        case .duplicateOption(let option):
            return "duplicate \(option) is not allowed"
        case .emptyValue(let option):
            return "\(option) value must not be empty"
        }
    }
}

public enum MSLCLIOptionsParser {
    public static func parseGlobalRuntimeOptions(_ raw: [String]) throws -> MSLGlobalRuntimeOptions {
        var i = 0
        var instanceName: String?
        var remaining: [String] = []
        let subcommands: Set<String> = [
            "run", "install", "uninstall", "cache", "config", "init",
            "memory", "port", "network", "status", "stop"
        ]

        while i < raw.count {
            let token = raw[i]
            if subcommands.contains(token) {
                remaining.append(contentsOf: raw[i...])
                break
            }
            if token == "--instance" || token == "-i" {
                guard i + 1 < raw.count else {
                    throw MSLCLIParseError.missingValue(option: "--instance")
                }
                if instanceName != nil {
                    throw MSLCLIParseError.duplicateOption(option: "--instance")
                }
                let value = raw[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else {
                    throw MSLCLIParseError.emptyValue(option: "--instance")
                }
                instanceName = value
                i += 2
                continue
            }
            remaining.append(token)
            i += 1
        }

        return MSLGlobalRuntimeOptions(instanceName: instanceName, remainingArguments: remaining)
    }
}
