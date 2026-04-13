import Foundation

public enum MSLCopyPath: Equatable {
    case local(String)
    case remote(String)
}

public struct MSLCopyTransfer: Equatable {
    public var src: MSLCopyPath
    public var dest: MSLCopyPath

    public init(src: MSLCopyPath, dest: MSLCopyPath) {
        self.src = src
        self.dest = dest
    }
}

public enum MSLCopyPathParser {
    public static func expandLocalPath(_ raw: String) throws -> String {
        if raw == "~" || raw.hasPrefix("~/") {
            return (raw as NSString).expandingTildeInPath
        }
        if raw.hasPrefix("~") {
            throw MSLRuntimeError("unsupported local path '\(raw)'; only ~ and ~/... are supported")
        }
        return raw
    }

    public static func parseOperand(_ raw: String) throws -> MSLCopyPath {
        if raw.hasPrefix("@:") {
            let path = String(raw.dropFirst(2))
            guard !path.isEmpty else {
                throw MSLRuntimeError("invalid VM path '\(raw)'; use @:/path")
            }
            if path.hasPrefix("~"), path != "~", !path.hasPrefix("~/") {
                throw MSLRuntimeError("unsupported VM path '\(raw)'; only @:~ and @:~/... are supported")
            }
            return .remote(path)
        }
        if raw.hasPrefix("@") {
            throw MSLRuntimeError("invalid VM path '\(raw)'; use @:/path")
        }
        return .local(raw)
    }

    public static func parseTransfer(
        src: String,
        dest: String,
        recursive: Bool,
        fileManager: FileManager = .default
    ) throws -> MSLCopyTransfer {
        let parsedSrc = try parseOperand(src)
        let parsedDest = try parseOperand(dest)
        switch (parsedSrc, parsedDest) {
        case (.local, .local):
            throw MSLRuntimeError("msl cp requires exactly one VM path using @:/path")
        case (.remote, .remote):
            throw MSLRuntimeError("msl cp does not support VM-to-VM copies")
        case (.local(let localPath), .remote):
            let expandedLocalPath = try expandLocalPath(localPath)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: expandedLocalPath, isDirectory: &isDirectory), isDirectory.boolValue, !recursive {
                throw MSLRuntimeError("omitting directory '\(localPath)'; use -r to copy directories")
            }
        case (.remote, .local):
            if case .local(let localPath) = parsedDest {
                _ = try expandLocalPath(localPath)
            }
            break
        }
        return MSLCopyTransfer(src: parsedSrc, dest: parsedDest)
    }
}
