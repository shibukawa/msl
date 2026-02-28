import Foundation

enum DNSMode: String {
    case host
    case manual
    case unmanaged
}

struct HostResolverSnapshot {
    var nameservers: [String]
    var searchDomains: [String]
    var capturedAtEpochMs: Int64
    var hash: String
}

struct ResolvedDNSPolicy {
    var mode: DNSMode
    var nameservers: [String]
    var searchDomains: [String]
    var resolverBackend: String
}

struct DNSPolicyResolver {
    static let defaultResolverBackend = "replace_resolv_conf"

    func resolve(
        instancePolicy: DistributionNetworkDNSPolicy?,
        globalConfig: MSLConfig.NetworkDNSConfig?,
        hostSnapshot: HostResolverSnapshot?
    ) throws -> ResolvedDNSPolicy {
        let mergedMode = normalizeMode(instancePolicy?.mode)
            ?? normalizeMode(globalConfig?.mode)
            ?? .host

        let resolverBackend = normalizeResolverBackend(instancePolicy?.resolverBackend)

        switch mergedMode {
        case .host:
            guard let hostSnapshot else {
                throw MSLRuntimeError("dns policy resolution failed: host resolver snapshot unavailable")
            }
            let nameservers = sanitizeNameservers(hostSnapshot.nameservers)
            if nameservers.isEmpty {
                throw MSLRuntimeError("dns policy resolution failed: no host nameserver detected")
            }
            return ResolvedDNSPolicy(
                mode: .host,
                nameservers: nameservers,
                searchDomains: sanitizeSearchDomains(hostSnapshot.searchDomains),
                resolverBackend: resolverBackend
            )
        case .manual:
            let rawNameservers = (instancePolicy?.manualNameservers ?? globalConfig?.manualNameservers) ?? []
            let nameservers = sanitizeNameservers(rawNameservers)
            if nameservers.isEmpty {
                throw MSLRuntimeError("invalid manual DNS config: at least one nameserver is required")
            }
            let rawSearch = (instancePolicy?.manualSearchDomains ?? globalConfig?.manualSearchDomains) ?? []
            return ResolvedDNSPolicy(
                mode: .manual,
                nameservers: nameservers,
                searchDomains: sanitizeSearchDomains(rawSearch),
                resolverBackend: resolverBackend
            )
        case .unmanaged:
            return ResolvedDNSPolicy(
                mode: .unmanaged,
                nameservers: [],
                searchDomains: [],
                resolverBackend: resolverBackend
            )
        }
    }

    private func normalizeMode(_ raw: String?) -> DNSMode? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }
        guard let mode = DNSMode(rawValue: value) else {
            return nil
        }
        return mode
    }

    private func normalizeResolverBackend(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? Self.defaultResolverBackend : trimmed
    }

    private func sanitizeNameservers(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in raw {
            let candidate = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidIPAddress(candidate) else { continue }
            if seen.insert(candidate).inserted {
                out.append(candidate)
            }
        }
        return out
    }

    private func sanitizeSearchDomains(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in raw {
            let candidate = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidSearchDomain(candidate) else { continue }
            if seen.insert(candidate).inserted {
                out.append(candidate)
            }
        }
        return out
    }

    private func isValidIPAddress(_ value: String) -> Bool {
        if value.contains(":") {
            return !value.isEmpty
        }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        for p in parts {
            guard let n = Int(p), n >= 0 && n <= 255 else { return false }
        }
        return true
    }

    private func isValidSearchDomain(_ value: String) -> Bool {
        if value.isEmpty || value.count > 253 { return false }
        if value.contains(" ") || value.contains("/") { return false }
        return true
    }
}

struct HostResolverSnapshotProvider {
    func capture() -> HostResolverSnapshot {
        let now = nowEpochMs()
        let resolved = captureViaScutil() ?? captureViaResolvConf()
        let nameservers = resolved?.nameservers ?? []
        let searchDomains = resolved?.searchDomains ?? []
        let hash = "\(nameservers.joined(separator: ","))|\(searchDomains.joined(separator: ","))"
        return HostResolverSnapshot(
            nameservers: nameservers,
            searchDomains: searchDomains,
            capturedAtEpochMs: now,
            hash: hash
        )
    }

    private func captureViaScutil() -> (nameservers: [String], searchDomains: [String])? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        process.arguments = ["--dns"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        var nameservers: [String] = []
        var searchDomains: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = line.trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("nameserver[") {
                if let idx = raw.firstIndex(of: ":") {
                    nameservers.append(String(raw[raw.index(after: idx)...]).trimmingCharacters(in: .whitespaces))
                }
            } else if raw.hasPrefix("search domain[") || raw.hasPrefix("domain[") {
                if let idx = raw.firstIndex(of: ":") {
                    searchDomains.append(String(raw[raw.index(after: idx)...]).trimmingCharacters(in: .whitespaces))
                }
            }
        }
        if nameservers.isEmpty {
            return nil
        }
        return (nameservers, searchDomains)
    }

    private func captureViaResolvConf() -> (nameservers: [String], searchDomains: [String])? {
        guard let text = try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8) else {
            return nil
        }
        var nameservers: [String] = []
        var searchDomains: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.hasPrefix("#") || raw.isEmpty {
                continue
            }
            if raw.hasPrefix("nameserver ") {
                nameservers.append(String(raw.dropFirst("nameserver ".count)).trimmingCharacters(in: .whitespaces))
            } else if raw.hasPrefix("search ") {
                let items = raw.dropFirst("search ".count).split(separator: " ").map { String($0) }
                searchDomains.append(contentsOf: items)
            }
        }
        if nameservers.isEmpty {
            return nil
        }
        return (nameservers, searchDomains)
    }
}
