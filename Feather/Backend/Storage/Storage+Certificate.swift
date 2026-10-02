//
//  Storage+Certificate.swift
//  Feather
//
//  Created by samara on 16.04.2025.
//

import CoreData
import UIKit.UIImpactFeedbackGenerator
import ZsignSwift

// MARK: - Class extension: certificate
extension Storage {
	func addCertificate(
		uuid: String,
		password: String? = nil,
		nickname: String? = nil,
		ppq: Bool = false,
		expiration: Date,
		isDefault: Bool = false,
		completion: @escaping (Error?) -> Void
	) {
		let generator = UIImpactFeedbackGenerator(style: .light)
		
		let new = CertificatePair(context: context)
		new.uuid = uuid
		new.date = Date()
		new.password = password
		new.ppQCheck = ppq
		new.expiration = expiration
		new.nickname = nickname
		new.isDefault = isDefault
		Storage.shared.revokagedCertificate(for: new)
		saveContext()
		generator.impactOccurred()
		completion(nil)
	}
	
	func deleteCertificate(for cert: CertificatePair) {
		if let url = getUuidDirectory(for: cert) {
			try? FileManager.default.removeItem(at: url)
		}
		context.delete(cert)
		saveContext()
	}
	
	func getCertificate(for index: Int) -> CertificatePair? {
		let fetchRequest: NSFetchRequest<CertificatePair> = CertificatePair.fetchRequest()
		fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)]

		guard
			let results = try? context.fetch(fetchRequest),
			index >= 0 && index < results.count
		else {
			return nil
		}
		
		return results[index]
	}
	
	func revokagedCertificate(for cert: CertificatePair) {
		guard !cert.revoked else { return }
		
		Zsign.checkRevokage(
			provisionPath: Storage.shared.getFile(.provision, from: cert)?.path ?? "",
			p12Path: Storage.shared.getFile(.certificate, from: cert)?.path ?? "",
			p12Password: cert.password ?? ""
		) { (status, _, _) in
			if status == 1 {
				DispatchQueue.main.async {
					cert.revoked = true
					self.saveContext()
				}
			}
		}
	}
	
	enum FileRequest: String {
		case certificate = "p12"
		case provision = "mobileprovision"
	}
	
	func getFile(_ type: FileRequest, from cert: CertificatePair) -> URL? {
		guard let url = getUuidDirectory(for: cert) else {
			return nil
		}
		
		return FileManager.default.getPath(in: url, for: type.rawValue)
	}
	
	func getProvisionFileDecoded(for cert: CertificatePair) -> Certificate? {
		guard let url = getFile(.provision, from: cert) else {
			return nil
		}
		
		let read = CertificateReader(url)
		return read.decoded
	}
	
	func getUuidDirectory(for cert: CertificatePair) -> URL? {
		guard let uuid = cert.uuid else {
			return nil
		}
		
		return FileManager.default.certificates(uuid)
	}
	
	func getAllCertificates() -> [CertificatePair] {
		let fetchRequest: NSFetchRequest<CertificatePair> = CertificatePair.fetchRequest()
		fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)]
		return (try? context.fetch(fetchRequest)) ?? []
	}
}


enum ZagCertificateSelection {
	static let askEveryTimeKey = "ZagStore.askCertificateEveryTime"
	static let allowCustomisationKey = "ZagStore.allowSigningCustomisation"

	static var asksEveryTime: Bool {
		UserDefaults.standard.bool(forKey: askEveryTimeKey)
	}

	@MainActor
	static func chooseForSigning() async -> CertificatePair? {
		let certificates = Storage.shared.getAllCertificates()
		guard !certificates.isEmpty else { return nil }

		guard asksEveryTime else {
			let index = UserDefaults.standard.integer(forKey: "feather.selectedCert")
			return certificates.indices.contains(index) ? certificates[index] : nil
		}

		return await withCheckedContinuation { continuation in
			guard let presenter = UIApplication.topViewController() else {
				continuation.resume(returning: nil)
				return
			}

			let alert = UIAlertController(
				title: .localized("Choose Certificate"),
				message: .localized("Select the certificate to use for this signing."),
				preferredStyle: .actionSheet
			)

			for certificate in certificates {
				let decoded = Storage.shared.getProvisionFileDecoded(for: certificate)
				let title =
					certificate.nickname ??
					decoded?.Name ??
					decoded?.AppIDName ??
					.localized("Unknown")

				alert.addAction(
					UIAlertAction(title: title, style: .default) { _ in
						continuation.resume(returning: certificate)
					}
				)
			}

			alert.addAction(
				UIAlertAction(title: .localized("Cancel"), style: .cancel) { _ in
					continuation.resume(returning: nil)
				}
			)

			if let popover = alert.popoverPresentationController {
				popover.sourceView = presenter.view
				popover.sourceRect = CGRect(
					x: presenter.view.bounds.midX,
					y: presenter.view.bounds.maxY - 1,
					width: 1,
					height: 1
				)
				popover.permittedArrowDirections = []
			}

			presenter.present(alert, animated: true)
		}
	}
}
