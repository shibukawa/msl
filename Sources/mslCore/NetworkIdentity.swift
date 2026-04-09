import Foundation

struct GuestNetworkAddressInfo: Equatable {
    var guestIPv4: String?
    var hostGatewayIPv4: String?
}

public struct VMNetSharedNetwork: Equatable {
    public var subnetIPv4: String
    public var subnetMaskIPv4: String
    public var hostGatewayIPv4: String
    public var hostAlias: String

    public init(
        subnetIPv4: String,
        subnetMaskIPv4: String,
        hostGatewayIPv4: String,
        hostAlias: String
    ) {
        self.subnetIPv4 = subnetIPv4
        self.subnetMaskIPv4 = subnetMaskIPv4
        self.hostGatewayIPv4 = hostGatewayIPv4
        self.hostAlias = hostAlias
    }
}

public struct VMNetNetworkTopology: Equatable {
    public var instanceName: String
    public var sharedNetwork: VMNetSharedNetwork
    public var guestIPv4: String
    public var guestMACAddress: String
    public var hostAlias: String
    public var serviceHostname: String

    public init(
        instanceName: String,
        sharedNetwork: VMNetSharedNetwork,
        guestIPv4: String,
        guestMACAddress: String,
        hostAlias: String,
        serviceHostname: String
    ) {
        self.instanceName = instanceName
        self.sharedNetwork = sharedNetwork
        self.guestIPv4 = guestIPv4
        self.guestMACAddress = guestMACAddress
        self.hostAlias = hostAlias
        self.serviceHostname = serviceHostname
    }

    public var subnetIPv4: String { sharedNetwork.subnetIPv4 }
    public var subnetMaskIPv4: String { sharedNetwork.subnetMaskIPv4 }
    public var hostIPv4: String { sharedNetwork.hostGatewayIPv4 }
}

struct ManagedHostsRenderResult: Equatable {
    var rendered: String
    var conflicts: [String]
}

enum NetworkIdentity {
    static let networkMode = "vmnet-shared"
    static let hostAlias = "host.msl.localhost"
    static let managedHostsCommentPrefix = "# msl-managed"
    private static let sharedSubnetIPv4 = "10.77.0.0"
    private static let sharedSubnetMaskIPv4 = "255.255.255.0"
    private static let sharedHostGatewayIPv4 = "10.77.0.1"
    private static let minGuestHostOctet = 2
    private static let maxGuestHostOctet = 254

    static func sharedNetwork() -> VMNetSharedNetwork {
        VMNetSharedNetwork(
            subnetIPv4: sharedSubnetIPv4,
            subnetMaskIPv4: sharedSubnetMaskIPv4,
            hostGatewayIPv4: sharedHostGatewayIPv4,
            hostAlias: hostAlias
        )
    }

    static func serviceHostname(for instanceName: String) -> String {
        "\(normalizedDNSLabel(instanceName)).msl.localhost"
    }

    static func serviceHostnamePatternDescription(for instanceName: String) -> String {
        "\(serviceHostname(for: instanceName)):<port>"
    }

    static func vmnetTopology(
        for instanceName: String,
        reservedGuestIPv4s: Set<String> = []
    ) -> VMNetNetworkTopology {
        let network = sharedNetwork()
        let hash = stableFNV1a32(instanceName)
        let totalGuestSlots = maxGuestHostOctet - minGuestHostOctet + 1
        let networkPrefix = network.subnetIPv4.split(separator: ".").dropLast().joined(separator: ".")
        let serviceHostname = serviceHostname(for: instanceName)
        var selectedGuestIPv4: String?
        var selectedMacAddress: String?

        for probe in 0..<totalGuestSlots {
            let offset = Int((UInt32(probe) &+ hash) % UInt32(totalGuestSlots))
            let hostOctet = minGuestHostOctet + offset
            let guestIPv4 = "\(networkPrefix).\(hostOctet)"
            if reservedGuestIPv4s.contains(guestIPv4) {
                continue
            }
            let macSeed = hash &+ UInt32(probe)
            let macBytes: [UInt8] = [
                0x02,
                0x6d,
                UInt8((macSeed >> 24) & 0xff),
                UInt8((macSeed >> 16) & 0xff),
                UInt8((macSeed >> 8) & 0xff),
                UInt8(macSeed & 0xff)
            ]
            selectedGuestIPv4 = guestIPv4
            selectedMacAddress = macBytes.map { String(format: "%02x", $0) }.joined(separator: ":")
            break
        }

        let guestIPv4 = selectedGuestIPv4 ?? "\(networkPrefix).\(minGuestHostOctet)"
        let guestMACAddress = selectedMacAddress ?? "02:6d:00:00:00:01"

        return VMNetNetworkTopology(
            instanceName: instanceName,
            sharedNetwork: network,
            guestIPv4: guestIPv4,
            guestMACAddress: guestMACAddress,
            hostAlias: hostAlias,
            serviceHostname: serviceHostname
        )
    }

    static func parseGuestAddressProbeOutput(_ text: String) -> GuestNetworkAddressInfo {
        var info = GuestNetworkAddressInfo()

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = line.firstIndex(of: "=") else {
                continue
            }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedValue = value.isEmpty ? nil : value

            switch key {
            case "guest_ipv4":
                info.guestIPv4 = normalizedValue
            case "host_gateway_ipv4":
                info.hostGatewayIPv4 = normalizedValue
            default:
                continue
            }
        }

        return info
    }

    static func renderGuestHostsFile(existing: String, hostGatewayIPv4: String, hostAlias: String = hostAlias) -> String {
        let line = managedGuestAliasLine(hostGatewayIPv4: hostGatewayIPv4, hostAlias: hostAlias)
        return renderHostsFileReplacingManagedLines(
            existing: existing,
            desiredLines: [line],
            managedHostnames: [hostAlias]
        ).rendered
    }

    static func reconcileHostHostsFile(existing: String, topologies: [VMNetNetworkTopology]) -> ManagedHostsRenderResult {
        let desiredHostnames = Set(topologies.map(\.serviceHostname))
        let nonManagedConflictHostnames = detectUnmanagedConflicts(existing: existing, desiredHostnames: desiredHostnames)
        let desiredLines = topologies
            .filter { !nonManagedConflictHostnames.contains($0.serviceHostname) }
            .sorted { $0.serviceHostname < $1.serviceHostname }
            .map(managedHostServiceLine(for:))

        return renderHostsFileReplacingManagedLines(
            existing: existing,
            desiredLines: desiredLines,
            managedHostnames: Array(desiredHostnames)
        ).withConflicts(nonManagedConflictHostnames.sorted())
    }

    static func managedHostServiceLine(for topology: VMNetNetworkTopology) -> String {
        "\(topology.guestIPv4) \(topology.serviceHostname) \(managedHostsCommentPrefix) instance=\(topology.instanceName) net=\(networkMode)"
    }

    static func managedGuestAliasLine(hostGatewayIPv4: String, hostAlias: String = hostAlias) -> String {
        "\(hostGatewayIPv4) \(hostAlias) \(managedHostsCommentPrefix) alias=host net=\(networkMode)"
    }

    static func normalizedDNSLabel(_ raw: String) -> String {
        var out = ""
        var previousSeparator = false

        for scalar in raw.unicodeScalars {
            let normalized: Character
            if CharacterSet.alphanumerics.contains(scalar) {
                normalized = Character(String(scalar).lowercased())
            } else {
                normalized = "-"
            }

            if normalized == "-" {
                if previousSeparator {
                    continue
                }
                previousSeparator = true
                out.append(normalized)
                continue
            }

            previousSeparator = false
            out.append(normalized)
        }

        var candidate = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if candidate.isEmpty {
            candidate = "msl"
        }
        if candidate.count > 63 {
            candidate = String(candidate.prefix(63)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if candidate.isEmpty {
                candidate = "msl"
            }
        }
        return candidate
    }

    private static func renderHostsFileReplacingManagedLines(
        existing: String,
        desiredLines: [String],
        managedHostnames: [String]
    ) -> ManagedHostsRenderResult {
        let managedHostnameSet = Set(managedHostnames)
        var lines: [String] = []

        for raw in existing.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                lines.append(line)
                continue
            }
            if isManagedHostsLine(trimmed) {
                continue
            }
            let fields = trimmed.split(whereSeparator: \.isWhitespace)
            if fields.count >= 2 && fields.dropFirst().contains(where: { managedHostnameSet.contains(String($0)) }) {
                lines.append(line)
                continue
            }
            lines.append(line)
        }

        lines.append(contentsOf: desiredLines)
        let rendered = lines.joined(separator: "\n") + "\n"
        return ManagedHostsRenderResult(rendered: rendered, conflicts: [])
    }

    private static func detectUnmanagedConflicts(existing: String, desiredHostnames: Set<String>) -> [String] {
        var conflicts = Set<String>()
        for raw in existing.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") || isManagedHostsLine(line) {
                continue
            }
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count < 2 {
                continue
            }
            for hostname in fields.dropFirst() where desiredHostnames.contains(String(hostname)) {
                conflicts.insert(String(hostname))
            }
        }
        return Array(conflicts)
    }

    private static func isManagedHostsLine(_ line: String) -> Bool {
        line.contains(managedHostsCommentPrefix)
    }

    private static func stableFNV1a32(_ raw: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in raw.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash
    }
}

private extension ManagedHostsRenderResult {
    func withConflicts(_ conflicts: [String]) -> ManagedHostsRenderResult {
        ManagedHostsRenderResult(rendered: rendered, conflicts: conflicts)
    }
}
