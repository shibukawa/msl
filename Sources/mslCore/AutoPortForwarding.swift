import Foundation

struct EffectivePortMappings {
    var mappings: [PortMapping]
    var manualHostPorts: Set<Int>
    var autoHostPorts: Set<Int>

    static let empty = EffectivePortMappings(mappings: [], manualHostPorts: [], autoHostPorts: [])
}

enum AutoPortForwardingPlanner {
    static func merge(manualMappings: [PortMapping], autoHostPorts: Set<Int>) -> EffectivePortMappings {
        var mergedByHostPort: [Int: PortMapping] = [:]
        var manualHostPorts = Set<Int>()

        for mapping in manualMappings.sorted(by: { $0.hostPort < $1.hostPort }) {
            mergedByHostPort[mapping.hostPort] = mapping
            manualHostPorts.insert(mapping.hostPort)
        }

        var effectiveAutoPorts = Set<Int>()
        for hostPort in autoHostPorts.sorted() {
            guard mergedByHostPort[hostPort] == nil else {
                continue
            }
            mergedByHostPort[hostPort] = PortMapping(hostPort: hostPort, guestPort: hostPort)
            effectiveAutoPorts.insert(hostPort)
        }

        let mappings = mergedByHostPort.values.sorted { $0.hostPort < $1.hostPort }
        return EffectivePortMappings(
            mappings: mappings,
            manualHostPorts: manualHostPorts,
            autoHostPorts: effectiveAutoPorts
        )
    }
}

enum GuestListeningPortDetector {
    static func discoverableHostPorts(
        fromProcNetTCP text: String,
        allowedHostPorts: ClosedRange<Int> = 1...65_535
    ) -> Set<Int> {
        var ports = Set<Int>()

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else {
                continue
            }

            let columns = line.split(whereSeparator: { $0.isWhitespace })
            guard columns.count >= 4 else {
                continue
            }

            let state = String(columns[3]).uppercased()
            guard state == "0A" else {
                continue
            }

            let localParts = columns[1].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard localParts.count == 2 else {
                continue
            }

            let localAddressHex = String(localParts[0]).uppercased()
            let localPortHex = String(localParts[1]).uppercased()
            guard let localPort = Int(localPortHex, radix: 16), (1...65_535).contains(localPort) else {
                continue
            }
            guard allowedHostPorts.contains(localPort) else {
                continue
            }
            guard isReachableFromHost(localAddressHex: localAddressHex) else {
                continue
            }

            ports.insert(localPort)
        }

        return ports
    }

    private static func isReachableFromHost(localAddressHex: String) -> Bool {
        guard localAddressHex.count == 8 else {
            return false
        }
        if localAddressHex == "00000000" {
            return true
        }
        guard let octets = decodeIPv4Octets(littleEndianHex: localAddressHex), octets.count == 4 else {
            return false
        }

        // 127.x.x.x loopback listeners are not reachable via guest vmnet IP.
        if octets[0] == 127 {
            return false
        }
        return true
    }

    private static func decodeIPv4Octets(littleEndianHex: String) -> [Int]? {
        guard littleEndianHex.count == 8 else {
            return nil
        }

        var bytes: [Int] = []
        var index = littleEndianHex.startIndex
        while index < littleEndianHex.endIndex {
            let next = littleEndianHex.index(index, offsetBy: 2)
            let part = String(littleEndianHex[index..<next])
            guard let value = Int(part, radix: 16) else {
                return nil
            }
            bytes.append(value)
            index = next
        }

        return bytes.reversed()
    }
}
