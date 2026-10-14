import Foundation
import CryptoKit

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
    /// Diagnostic integrity check for thin arm64 CodeDirectory SHA-256 code pages.
    /// This does NOT authenticate the CodeDirectory, CMS, certificates, special
    /// slots, nested code or resource seal, and never authorizes installation.
    static func inspectCodePageHashes(at executable: URL) throws -> String {
        let data = try Data(contentsOf: executable, options: .mappedIfSafe)
        func le32(_ p: Int) throws -> Int {
            guard p >= 0, p <= data.count - 4 else { throw InspectionError.malformedSignature }
            return Int(data[p]) | (Int(data[p+1]) << 8) |
                (Int(data[p+2]) << 16) | (Int(data[p+3]) << 24)
        }
        func be32(_ p: Int) throws -> Int {
            guard p >= 0, p <= data.count - 4 else { throw InspectionError.malformedSignature }
            return (Int(data[p]) << 24) | (Int(data[p+1]) << 16) |
                (Int(data[p+2]) << 8) | Int(data[p+3])
        }
        guard try le32(0) == 0xfeedfacf else { throw InspectionError.unsupportedFormat }
        let ncmds = try le32(16), sizeofcmds = try le32(20)
        guard ncmds <= 4096, sizeofcmds <= data.count - 32 else {
            throw InspectionError.malformedSignature
        }
        let end = 32 + sizeofcmds
        var cursor = 32
        var signature: (Int, Int)?
        for _ in 0..<ncmds {
            guard cursor <= end - 8 else { throw InspectionError.malformedSignature }
            let cmd = try le32(cursor), size = try le32(cursor + 4)
            guard size >= 8, size <= end - cursor else { throw InspectionError.malformedSignature }
            if cmd == 0x1d {
                guard size >= 16, signature == nil else { throw InspectionError.malformedSignature }
                signature = (try le32(cursor + 8), try le32(cursor + 12))
            }
            cursor += size
        }
        guard let (offset, length) = signature, length >= 12,
              offset >= 0, offset <= data.count - length,
              try be32(offset) == 0xfade0cc0 else {
            throw InspectionError.malformedSignature
        }
        let total = try be32(offset + 4), count = try be32(offset + 8)
        guard total >= 12, total <= length, count <= 1024,
              count <= (total - 12) / 8 else { throw InspectionError.malformedSignature }
        var cd: (Int, Int)?
        for i in 0..<count {
            let entry = offset + 12 + i * 8
            let type = try be32(entry), relative = try be32(entry + 4)
            guard relative >= 12, relative <= total - 8 else {
                throw InspectionError.malformedSignature
            }
            let blob = offset + relative, blobLength = try be32(blob + 4)
            guard blobLength >= 8, blobLength <= total - relative else {
                throw InspectionError.malformedSignature
            }
            if type == 0 {
                guard cd == nil, try be32(blob) == 0xfade0c02 else {
                    throw InspectionError.malformedSignature
                }
                cd = (blob, blobLength)
            }
        }
        guard let (base, size) = cd, size >= 44 else {
            throw InspectionError.malformedSignature
        }
        let hashOffset = try be32(base + 16)
        let specialSlots = try be32(base + 24)
        let codeSlots = try be32(base + 28)
        let codeLimit = try be32(base + 32)
        let hashSize = Int(data[base + 36])
        let hashType = data[base + 37]
        let pageExponent = Int(data[base + 39])
        let pageSize = 1 << pageExponent
        guard hashType == 2, hashSize == 32, (pageExponent == 12 || pageExponent == 14),
              codeSlots > 0, codeSlots <= 100000,
              specialSlots <= 1024,
              hashOffset >= specialSlots * hashSize,
              hashOffset <= size,
              codeSlots <= (size - hashOffset) / hashSize,
              codeLimit <= offset,
              (codeLimit + pageSize - 1) / pageSize == codeSlots else {
            throw InspectionError.unsupportedFormat
        }
        for i in 0..<codeSlots {
            let start = i * pageSize
            let finish = min(start + pageSize, codeLimit)
            let digest = SHA256.hash(data: data[start..<finish])
            let slot = base + hashOffset + i * hashSize
            guard Data(digest) == data.subdata(in: slot..<(slot + hashSize)) else {
                return "FAIL — code page \\(i) hash mismatch"
            }
        }
        return "PASS — \\(codeSlots) SHA-256 code pages (integrity only; unauthenticated)"
    }

}
