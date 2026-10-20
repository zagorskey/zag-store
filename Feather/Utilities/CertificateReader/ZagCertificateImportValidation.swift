//
//  ZagCertificateImportValidation.swift
//  Zag Store
//
//  Validate imported signing files without persisting or exposing secrets.
//

import Foundation
import Security
import CoreFoundation

enum ZagCertificateImportValidation {
    struct Result: Sendable {
        let isValid: Bool
        let message: String

        static func accept() -> Self {
            .init(isValid: true, message: "Signing identity and profile match.")
        }
        static func reject(_ reason: String) -> Self {
            .init(isValid: false, message: reason)
        }
    }

    static func validate(
        p12: URL, provision: URL, password: String, existingUUIDs: Set<String>
    ) -> Result {
        let p12Access = p12.startAccessingSecurityScopedResource()
        let provisionAccess = provision.startAccessingSecurityScopedResource()
        defer {
            if p12Access { p12.stopAccessingSecurityScopedResource() }
            if provisionAccess { provision.stopAccessingSecurityScopedResource() }
        }

        // Keep malformed or unexpectedly large imports out of the signing library.
        guard let p12Bytes = _readLimited(p12, limit: 16 * 1024 * 1024) else {
            return .reject("The P12 file is missing, unreadable or larger than 16 MB.")
        }
        guard _readLimited(provision, limit: 16 * 1024 * 1024) != nil else {
            return .reject("The provisioning file is missing, unreadable or larger than 16 MB.")
        }
        guard let profile = CertificateReader(provision).decoded else {
            return .reject("The provisioning profile could not be decoded.")
        }
        guard profile.CreationDate <= Date(), profile.ExpirationDate > Date() else {
            return .reject("The provisioning profile is not currently valid.")
        }
        guard !existingUUIDs.contains(profile.UUID.lowercased()) else {
            return .reject("This provisioning profile is already in your Certificate Library.")
        }
        guard let authorized = profile.DeveloperCertificates, !authorized.isEmpty else {
            return .reject("The provisioning profile has no embedded developer certificates.")
        }

        var imported: CFArray?
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        let status = SecPKCS12Import(p12Bytes as CFData, options, &imported)
        if status == errSecAuthFailed {
            return .reject("The P12 password was rejected.")
        }
        guard status == errSecSuccess, let entries = imported as? [[String: Any]] else {
            return .reject("The P12 archive could not be decoded with this password.")
        }

        // SecIdentity is a CoreFoundation type; verify its type before bridging.
        guard let raw = entries.compactMap({ $0[kSecImportItemIdentity as String] }).first(where: {
            CFGetTypeID($0 as CFTypeRef) == SecIdentityGetTypeID()
        }) else {
            return .reject("No signing identity was found in the P12 archive.")
        }
        let identity = raw as! SecIdentity

        var key: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess, key != nil else {
            return .reject("The P12 does not contain an accessible private key.")
        }
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate else {
            return .reject("The P12 signing certificate could not be read.")
        }
        let der = SecCertificateCopyData(certificate) as Data
        guard authorized.contains(der) else {
            return .reject("The P12 signing certificate does not match the provisioning profile.")
        }

        return .accept()
    }

    private static func _readLimited(_ url: URL, limit: Int) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize,
              size > 0, size <= limit else { return nil }
        return try? Data(contentsOf: url)
    }
}
