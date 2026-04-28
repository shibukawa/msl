import Foundation

enum MSLInitBootTransferProtocol {
    static let magic = "MSLB2"
    static let helloOp = "HELLO"
    static let controlRole = "control"
    static let sidebandRolePrefix = "sideband:"
    static let metadataVersion: UInt32 = 1
    static let requiredFlag: UInt8 = 0x01

    struct Hello: Equatable {
        var version: String
        var role: String
        var detail: String?

        var initMode: String? {
            role == "bootloader" ? detail : nil
        }
    }

    enum TargetKind: UInt8, Equatable {
        case bootloader = 1
        case environment = 2
        case execEnv = 3
    }

    struct MetadataRecord: Equatable {
        var targetKind: TargetKind
        var flags: UInt8
        var entry: String

        var isRequired: Bool {
            (flags & requiredFlag) != 0
        }
    }

    static func parseHelloLine(_ line: String) -> Hello? {
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
        guard parts.count == 4,
              parts[0] == magic,
              parts[1] == helloOp else {
            return nil
        }
        let payload = parts[3]
        if payload == controlRole {
            return Hello(version: parts[2], role: controlRole, detail: nil)
        }
        if payload.hasPrefix(sidebandRolePrefix) {
            return Hello(
                version: parts[2],
                role: "sideband",
                detail: String(payload.dropFirst(sidebandRolePrefix.count))
            )
        }
        return Hello(version: parts[2], role: "bootloader", detail: payload)
    }

    static func encodeMetadataBlock(version: UInt32 = metadataVersion, records: [MetadataRecord]) throws -> Data {
        var out = Data()
        appendLE(version, to: &out)
        appendLE(UInt32(records.count), to: &out)
        for record in records {
            guard record.flags & ~requiredFlag == 0 else {
                throw MSLRuntimeError("unsupported boot metadata flags: \(record.flags)")
            }
            guard let entryData = record.entry.data(using: .utf8) else {
                throw MSLRuntimeError("boot metadata entry is not UTF-8 encodable")
            }
            out.append(record.targetKind.rawValue)
            out.append(record.flags)
            appendLE(UInt16(0), to: &out)
            appendLE(UInt32(entryData.count), to: &out)
            out.append(entryData)
        }
        return out
    }

    static func decodeMetadataBlock(_ data: Data) -> [MetadataRecord]? {
        guard data.count >= 8 else {
            return nil
        }
        var offset = 0
        guard let version: UInt32 = readLE(from: data, offset: &offset),
              version == metadataVersion,
              let recordCount: UInt32 = readLE(from: data, offset: &offset) else {
            return nil
        }
        var records: [MetadataRecord] = []
        records.reserveCapacity(Int(recordCount))
        for _ in 0..<recordCount {
            guard offset + 8 <= data.count else {
                return nil
            }
            let targetRaw = data[offset]
            offset += 1
            let flags = data[offset]
            offset += 1
            guard flags & ~requiredFlag == 0 else {
                return nil
            }
            guard let _: UInt16 = readLE(from: data, offset: &offset),
                  let entryLen: UInt32 = readLE(from: data, offset: &offset) else {
                return nil
            }
            let length = Int(entryLen)
            guard offset + length <= data.count,
                  let targetKind = TargetKind(rawValue: targetRaw),
                  let entry = String(data: data[offset..<(offset + length)], encoding: .utf8) else {
                return nil
            }
            offset += length
            records.append(MetadataRecord(targetKind: targetKind, flags: flags, entry: entry))
        }
        guard offset == data.count else {
            return nil
        }
        return records
    }

    private static func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func readLE<T: FixedWidthInteger>(from data: Data, offset: inout Int) -> T? {
        let size = MemoryLayout<T>.size
        guard offset + size <= data.count else {
            return nil
        }
        let slice = data[offset..<(offset + size)]
        var value = T.zero
        withUnsafeMutableBytes(of: &value) { rawBuffer in
            rawBuffer.copyBytes(from: slice)
        }
        offset += size
        return T(littleEndian: value)
    }
}
