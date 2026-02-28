import Foundation

final class GuestIPResolver {
    private let explicitIP: String?
    private let lock = NSLock()
    private var lastSuccessfulIP: String?

    init(explicitIP: String?) {
        if let explicitIP, !explicitIP.isEmpty {
            self.explicitIP = explicitIP
        } else {
            self.explicitIP = nil
        }
    }

    func candidateIPs() -> [String] {
        var result: [String] = []
        if let explicitIP {
            result.append(explicitIP)
        }

        lock.lock()
        let cached = lastSuccessfulIP
        lock.unlock()
        if let cached, !result.contains(cached) {
            result.append(cached)
        }

        for ip in discoverFromArp() where !result.contains(ip) {
            result.append(ip)
        }

        // Common vmnet fallback candidates.
        for ip in ["192.168.64.2", "192.168.64.3", "192.168.64.4"] where !result.contains(ip) {
            result.append(ip)
        }

        if result.isEmpty {
            result.append("127.0.0.1")
        }
        return result
    }

    func reportSuccess(ip: String) {
        lock.lock()
        lastSuccessfulIP = ip
        lock.unlock()
    }

    func preferredGuestIPHint() -> String? {
        for ip in candidateIPs() where ip != "127.0.0.1" {
            return ip
        }
        return nil
    }

    private func discoverFromArp() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        process.arguments = ["-an"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = nil
        process.standardInput = nil

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return []
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else {
                return []
            }
            return Self.parseArpOutput(text)
        } catch {
            return []
        }
    }

    static func parseArpOutput(_ text: String) -> [String] {
        var out: [String] = []
        let regex = try? NSRegularExpression(pattern: #"^\? \(([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\) at .* on ([^ ]+) "#, options: [.anchorsMatchLines])
        guard let regex else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        for m in matches {
            guard m.numberOfRanges >= 3 else { continue }
            let ip = ns.substring(with: m.range(at: 1))
            let iface = ns.substring(with: m.range(at: 2))
            guard isPrivateIPv4(ip) else { continue }
            guard iface.hasPrefix("bridge") || iface.hasPrefix("vmnet") || iface.hasPrefix("vmenet") else { continue }
            if !out.contains(ip) {
                out.append(ip)
            }
        }
        return out
    }
}

private func isPrivateIPv4(_ ip: String) -> Bool {
    let parts = ip.split(separator: ".").compactMap { Int($0) }
    guard parts.count == 4 else { return false }
    let a = parts[0]
    let b = parts[1]
    if a == 10 { return true }
    if a == 172 && (16...31).contains(b) { return true }
    if a == 192 && b == 168 { return true }
    return false
}
