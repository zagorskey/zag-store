//
//  ZsignHandler.swift
//  Feather
//
//  Created by samara on 17.04.2025.
//

import Foundation
import ZsignSwift
import UIKit

final class ZsignHandler {
	var hadError: Error?
	
	private var _appUrl: URL
	private var _options: Options
	private var _certificate: CertificatePair?
	
	init(
		appUrl: URL,
		options: Options = OptionsManager.shared.options,
		cert: CertificatePair? = nil
	) {
		self._appUrl = appUrl
		self._options = options
		self._certificate = cert
	}
	
	func disinject() async throws {
		guard !_options.disInjectionFiles.isEmpty else {
			return
		}
		
		let bundle = Bundle(url: _appUrl)
		let execPath = _appUrl.appendingPathComponent(bundle?.exec ?? "").relativePath
		
		if !Zsign.removeDylibs(appExecutable: execPath, using: _options.disInjectionFiles) {
			throw SigningFileHandlerError.disinjectFailed
		}
	}
	
	func sign() async throws {
		guard let cert = _certificate else {
			throw SigningFileHandlerError.missingCertifcate
		}

		let provisionURL = Storage.shared.getFile(.provision, from: cert)

		// Zsign embeds the provisioning profile in the main app, but some
		// applications expect every bundled app extension to contain one too.
		// Reuse the selected profile for each .appex before recursively signing.
		if let provisionURL {
			try _embedProvisioningProfileInAppExtensions(provisionURL)
		}

		let generatedEntitlementsURL = try _generatedEntitlementsURLIfNeeded(for: cert)
		defer {
			if let generatedEntitlementsURL {
				try? FileManager.default.removeItem(at: generatedEntitlementsURL)
			}
		}

		let entitlementsURL = _options.appEntitlementsFile ?? generatedEntitlementsURL
		let succeeded = Zsign.sign(
			appPath: _appUrl.relativePath,
			provisionPath: provisionURL?.path ?? "",
			p12Path: Storage.shared.getFile(.certificate, from: cert)?.path ?? "",
			p12Password: cert.password ?? "",
			entitlementsPath: entitlementsURL?.path ?? "",
			removeProvision: !_options.removeProvisioning,
			completion: { _, error in
				self.hadError = error
			}
		)

		if !succeeded && hadError == nil {
			hadError = NSError(
				domain: "ZagStore.Zsign",
				code: 1,
				userInfo: [NSLocalizedDescriptionKey: "Zsign failed without returning an error."]
			)
		}
	}
	

	private func _generatedEntitlementsURLIfNeeded(for cert: CertificatePair) throws -> URL? {
		guard _options.appEntitlementsFile == nil,
			let profile = Storage.shared.getProvisionFileDecoded(for: cert),
			let profileEntitlements = profile.Entitlements,
			let teamID = profile.TeamIdentifier.first,
			let bundleIdentifier = Bundle(url: _appUrl)?.bundleIdentifier
		else {
			return nil
		}

		var entitlements = profileEntitlements.mapValues { $0.value }
		let wildcardGroup = "\(teamID).*"
		let appKeychainGroup = "\(teamID).\(bundleIdentifier)"

		if let groups = entitlements["keychain-access-groups"] as? [String],
			groups.contains(wildcardGroup) {
			entitlements["keychain-access-groups"] = groups.map {
				$0 == wildcardGroup ? appKeychainGroup : $0
			}
		}

		guard PropertyListSerialization.propertyList(
			entitlements,
			isValidFor: .xml
		) else {
			return nil
		}

		let data = try PropertyListSerialization.data(
			fromPropertyList: entitlements,
			format: .xml,
			options: 0
		)
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("zag-entitlements-\(UUID().uuidString).plist")
		try data.write(to: url, options: .atomic)
		return url
	}

	private func _embedProvisioningProfileInAppExtensions(_ provisionURL: URL) throws {
		guard let enumerator = FileManager.default.enumerator(
			at: _appUrl,
			includingPropertiesForKeys: nil,
			options: [.skipsHiddenFiles]
		) else {
			return
		}

		for case let bundleURL as URL in enumerator
		where bundleURL.pathExtension == "appex" {
			let destinationURL = bundleURL.appendingPathComponent(
				"embedded.mobileprovision"
			)

			try? FileManager.default.removeItem(at: destinationURL)
			try FileManager.default.copyItem(
				at: provisionURL,
				to: destinationURL
			)

			// App extensions cannot contain nested app extensions.
			enumerator.skipDescendants()
		}
	}

	func adhocSign() async throws {
		let _ = Zsign.sign(
			appPath: _appUrl.relativePath,
			entitlementsPath: _options.appEntitlementsFile?.path ?? "",
			adhoc: true,
			removeProvision: !_options.removeProvisioning,
			completion: { _, error in
				self.hadError = error
			}
		)
	}
}
