import Foundation
import Darwin

public struct StorageImageBuildProfile: Equatable {
    public struct Image: Equatable {
        public var base: String
        public var sizeGB: Int
    }

    public struct Compression: Equatable {
        public var defaultMode: String
        public var pathPolicies: [CompressionPathPolicyEntry]
    }

    public struct HostShareMount: Equatable {
        public var host: String
        public var guest: String
        public var readOnly: Bool
    }

    public struct Mounts: Equatable {
        public var hostShares: [HostShareMount]
    }

    public struct Bind: Equatable {
        public var ssh: Bool
        public var gitconfig: Bool
    }

    public struct User: Equatable {
        public var name: String
        public var uid: Int
        public var gid: Int
        public var inheritFromMac: Bool
    }

    public struct Env: Equatable {
        public var allow: [String]
        public var hostPrecedence: Bool
    }

    public struct Trim: Equatable {
        public var enableTimer: Bool
        public var manualCommand: String
    }

    public var schema: Int
    public var image: Image
    public var compression: Compression
    public var mounts: Mounts
    public var bind: Bind
    public var caches: [String: Bool]
    public var user: User
    public var env: Env
    public var trim: Trim

    public init(
        schema: Int,
        image: Image,
        compression: Compression,
        mounts: Mounts,
        bind: Bind,
        caches: [String: Bool],
        user: User,
        env: Env,
        trim: Trim
    ) {
        self.schema = schema
        self.image = image
        self.compression = compression
        self.mounts = mounts
        self.bind = bind
        self.caches = caches
        self.user = user
        self.env = env
        self.trim = trim
    }
}

public enum StorageImageProfileParser {
    public static func parse(_ raw: String, profileName: String) throws -> StorageImageBuildProfile {
        var schema = 1
        var imageBase = ""
        var imageSizeGB = 64
        var compressionDefault = "zstd:3"
        var compressionPolicies: [CompressionPathPolicyEntry] = []
        var hostShares: [StorageImageBuildProfile.HostShareMount] = []
        var bindSSH = false
        var bindGitConfig = true
        var caches: [String: Bool] = [
            "docker": false,
            "go": true,
            "apt": true,
            "apk": true
        ]
        var userName = ""
        var userUID = 0
        var userGID = 0
        var userInheritFromMac = true
        var envAllow = ["PATH", "LANG", "LC_ALL", "TERM"]
        var envHostPrecedence = false
        var trimEnableTimer = true
        var trimManualCommand = "fstrim -av"

        var currentSection = ""
        var currentArraySection = ""

        func sectionMatches(_ section: String, base: String) -> Bool {
            if section == base { return true }
            if section == "profiles.\(profileName).\(base)" { return true }
            return false
        }

        for line in raw.split(whereSeparator: \.isNewline) {
            let cleaned = stripTomlComment(from: String(line)).trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty { continue }

            if cleaned.hasPrefix("[[") && cleaned.hasSuffix("]]") {
                currentArraySection = String(cleaned.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                currentSection = ""
                continue
            }
            if cleaned.hasPrefix("[") && cleaned.hasSuffix("]") {
                currentSection = String(cleaned.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                currentArraySection = ""
                continue
            }

            guard let eq = cleaned.firstIndex(of: "=") else { continue }
            let key = cleaned[..<eq].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = cleaned[cleaned.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)

            if currentSection.isEmpty && currentArraySection.isEmpty {
                if key == "schema" {
                    schema = try parseInt(value, key: "schema")
                    continue
                }
            }

            if sectionMatches(currentSection, base: "image") {
                if key == "base" {
                    imageBase = try parseString(value, key: "image.base")
                } else if key == "size_gb" {
                    imageSizeGB = try parseInt(value, key: "image.size_gb")
                }
                continue
            }

            if sectionMatches(currentSection, base: "compression") {
                if key == "default" {
                    compressionDefault = try parseCompressionMode(value, key: "compression.default")
                }
                continue
            }

            if sectionMatches(currentArraySection, base: "compression.pathPolicies") {
                if key == "path" {
                    let path = try parseString(value, key: "compression.pathPolicies.path")
                    compressionPolicies.append(CompressionPathPolicyEntry(path: path, mode: ""))
                } else if key == "mode" {
                    let mode = try parseCompressionMode(value, key: "compression.pathPolicies.mode")
                    guard !compressionPolicies.isEmpty else {
                        throw MSLRuntimeError("invalid TOML: compression.pathPolicies.mode appears before path")
                    }
                    compressionPolicies[compressionPolicies.count - 1] = CompressionPathPolicyEntry(
                        path: compressionPolicies[compressionPolicies.count - 1].path,
                        mode: mode
                    )
                }
                continue
            }

            if sectionMatches(currentArraySection, base: "mounts.hostShares") {
                if key == "host" {
                    let host = try parseString(value, key: "mounts.hostShares.host")
                    hostShares.append(.init(host: host, guest: "", readOnly: false))
                } else if key == "guest" {
                    let guest = try parseString(value, key: "mounts.hostShares.guest")
                    guard !hostShares.isEmpty else {
                        throw MSLRuntimeError("invalid TOML: mounts.hostShares.guest appears before host")
                    }
                    hostShares[hostShares.count - 1].guest = guest
                } else if key == "readOnly" {
                    let readOnly = try parseBool(value, key: "mounts.hostShares.readOnly")
                    guard !hostShares.isEmpty else {
                        throw MSLRuntimeError("invalid TOML: mounts.hostShares.readOnly appears before host")
                    }
                    hostShares[hostShares.count - 1].readOnly = readOnly
                }
                continue
            }

            if sectionMatches(currentSection, base: "bind") {
                if key == "ssh" {
                    bindSSH = try parseBool(value, key: "bind.ssh")
                } else if key == "gitconfig" {
                    bindGitConfig = try parseBool(value, key: "bind.gitconfig")
                }
                continue
            }

            if sectionMatches(currentSection, base: "caches") {
                let flag = try parseBool(value, key: "caches.\(key)")
                caches[key.lowercased()] = flag
                continue
            }

            if sectionMatches(currentSection, base: "user") {
                if key == "name" {
                    userName = try parseString(value, key: "user.name")
                } else if key == "uid" {
                    userUID = try parseInt(value, key: "user.uid")
                } else if key == "gid" {
                    userGID = try parseInt(value, key: "user.gid")
                } else if key == "inheritFromMac" {
                    userInheritFromMac = try parseBool(value, key: "user.inheritFromMac")
                }
                continue
            }

            if sectionMatches(currentSection, base: "env") {
                if key == "allow" {
                    envAllow = try parseStringArray(value, key: "env.allow")
                } else if key == "hostPrecedence" {
                    envHostPrecedence = try parseBool(value, key: "env.hostPrecedence")
                }
                continue
            }

            if sectionMatches(currentSection, base: "trim") {
                if key == "enableTimer" {
                    trimEnableTimer = try parseBool(value, key: "trim.enableTimer")
                } else if key == "manualCommand" {
                    trimManualCommand = try parseString(value, key: "trim.manualCommand")
                }
                continue
            }
        }

        if imageBase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MSLRuntimeError("invalid TOML: image.base is required")
        }
        if imageSizeGB <= 0 {
            throw MSLRuntimeError("invalid TOML: image.size_gb must be > 0")
        }

        for policy in compressionPolicies {
            if policy.path.isEmpty || !policy.path.hasPrefix("/") {
                throw MSLRuntimeError("invalid TOML: compression.pathPolicies.path must be an absolute path")
            }
            _ = try parseCompressionMode("\"\(policy.mode)\"", key: "compression.pathPolicies.mode")
        }

        for mount in hostShares {
            if mount.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw MSLRuntimeError("invalid TOML: mounts.hostShares.host must not be empty")
            }
            if !mount.guest.hasPrefix("/") {
                throw MSLRuntimeError("invalid TOML: mounts.hostShares.guest must be an absolute path")
            }
        }

        if userInheritFromMac {
            userUID = Int(getuid())
            userGID = Int(getgid())
            if userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                userName = NSUserName()
            }
        }

        let profile = StorageImageBuildProfile(
            schema: schema,
            image: .init(base: imageBase, sizeGB: imageSizeGB),
            compression: .init(defaultMode: compressionDefault, pathPolicies: compressionPolicies),
            mounts: .init(hostShares: hostShares),
            bind: .init(ssh: bindSSH, gitconfig: bindGitConfig),
            caches: caches,
            user: .init(name: userName, uid: userUID, gid: userGID, inheritFromMac: userInheritFromMac),
            env: .init(allow: envAllow, hostPrecedence: envHostPrecedence),
            trim: .init(enableTimer: trimEnableTimer, manualCommand: trimManualCommand)
        )
        return profile
    }

    private static func parseString(_ raw: String, key: String) throws -> String {
        guard raw.hasPrefix("\"") && raw.hasSuffix("\"") else {
            throw MSLRuntimeError("invalid TOML: \(key) must be a string")
        }
        return String(raw.dropFirst().dropLast())
    }

    private static func parseBool(_ raw: String, key: String) throws -> Bool {
        let v = raw.lowercased()
        if v == "true" { return true }
        if v == "false" { return false }
        throw MSLRuntimeError("invalid TOML: \(key) must be boolean")
    }

    private static func parseInt(_ raw: String, key: String) throws -> Int {
        guard let value = Int(raw) else {
            throw MSLRuntimeError("invalid TOML: \(key) must be integer")
        }
        return value
    }

    private static func parseStringArray(_ raw: String, key: String) throws -> [String] {
        guard raw.hasPrefix("[") && raw.hasSuffix("]") else {
            throw MSLRuntimeError("invalid TOML: \(key) must be string array")
        }
        let data = Data(raw.utf8)
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let values = object as? [String] else {
            throw MSLRuntimeError("invalid TOML: \(key) must be string array")
        }
        return values
    }

    private static func parseCompressionMode(_ raw: String, key: String) throws -> String {
        let value = try parseString(raw, key: key)
        if value == "none" { return value }
        if value.hasPrefix("zstd:"), let level = Int(value.dropFirst("zstd:".count)), level >= 1 && level <= 19 {
            return value
        }
        throw MSLRuntimeError("invalid TOML: \(key) must be 'none' or 'zstd:<1-19>'")
    }

    private static func stripTomlComment(from line: String) -> String {
        var inString = false
        var escaped = false
        var output = ""
        for ch in line {
            if escaped {
                output.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" {
                output.append(ch)
                escaped = inString
                continue
            }
            if ch == "\"" {
                inString.toggle()
                output.append(ch)
                continue
            }
            if ch == "#", !inString {
                break
            }
            output.append(ch)
        }
        return output
    }
}
