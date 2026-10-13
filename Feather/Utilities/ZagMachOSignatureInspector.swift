import Foundation

/// Read-only inspection of the entitlement blob inside a thin, 64-bit Mach-O.
/// This is NOT cryptographic code-signature verification. Unsupported binaries
/// and malformed signatures fail closed.
enum ZagMachOSignatureInspector {
    enum InspectionError: Error {
        case unsupportedFormat
        case malformedSignature
        case missingEntitlements
    }

    static func entitlements(at executable: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: executable, options: .mappedIfSafe)
        func number(_ offset: Int, bigEndian: Bool = false) throws -> UInt32 {
            guard offset >= 0, offset <= data.count - 4 else {
                throw InspectionError.malformedSignature
            }
            let bytes = [UInt8](data[offset..<(offset + 4)])
            if bigEndian {
                return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            }
            return bytes.reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }

        // MH_MAGIC_64 in little-endian on iOS; fat binaries are deliberately
        // unsupported until slice selection is implemented and tested.
        guard try number(0) == 0xfeedfacf else {
            throw InspectionError.unsupportedFormat
        }
        let commandCount = Int(try number(16))
        let commandBytes = Int(try number(20))
        guard commandCount <= 4096, commandBytes <= data.count - 32 else {
            throw InspectionError.malformedSignature
        }
        let commandsEnd = 32 + commandBytes
        var cursor = 32
        var signatureOffset: Int?
        var signatureLength: Int?
        for _ in 0..<commandCount {
            guard cursor <= commandsEnd - 8 else {
                throw InspectionError.malformedSignature
            }
            let command = try number(cursor)
            let length = Int(try number(cursor + 4))
            guard length >= 8, length <= commandsEnd - cursor else {
                throw InspectionError.malformedSignature
            }
            if command == 0x1d { // LC_CODE_SIGNATURE
                guard length >= 16, signatureOffset == nil else {
                    throw InspectionError.malformedSignature
                }
                signatureOffset = Int(try number(cursor + 8))
                signatureLength = Int(try number(cursor + 12))
            }
            cursor += length
        }
        guard let offset = signatureOffset, let length = signatureLength,
              offset >= 0, length >= 12, offset <= data.count - length else {
            throw InspectionError.malformedSignature
        }

        // Embedded signature SuperBlob, CSMAGIC_EMBEDDED_SIGNATURE.
        guard try number(offset, bigEndian: true) == 0xfade0cc0,
              Int(try number(offset + 4, bigEndian: true)) <= length else {
            throw InspectionError.malformedSignature
        }
        let totalLength = Int(try number(offset + 4, bigEndian: true))
        let count = Int(try number(offset + 8, bigEndian: true))
        guard count <= 1024, count <= (totalLength - 12) / 8 else {
            throw InspectionError.malformedSignature
        }
        var result: [String: Any]?
        for index in 0..<count {
            let entry = offset + 12 + index * 8
            let type = try number(entry, bigEndian: true)
            let relativeOffset = Int(try number(entry + 4, bigEndian: true))
            guard relativeOffset >= 12, relativeOffset <= totalLength - 8 else {
                throw InspectionError.malformedSignature
            }
            let blob = offset + relativeOffset
            let blobLength = Int(try number(blob + 4, bigEndian: true))
            guard blobLength >= 8, blobLength <= totalLength - relativeOffset else {
                throw InspectionError.malformedSignature
            }
            if type == 5 { // CSSLOT_ENTITLEMENTS (XML)
                guard result == nil, try number(blob, bigEndian: true) == 0xfade7171 else {
                    throw InspectionError.malformedSignature
                }
                let payload = data.subdata(in: (blob + 8)..<(blob + blobLength))
                guard let plist = try PropertyListSerialization.propertyList(
                    from: payload, options: [], format: nil
                ) as? [String: Any] else {
                    throw InspectionError.malformedSignature
                }
                result = plist
            }
        }
        guard let result else { throw InspectionError.missingEntitlements }
        return result
    }
}
