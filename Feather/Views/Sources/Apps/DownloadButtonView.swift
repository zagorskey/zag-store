//
//  DownloadButtonView.swift
//  Feather
//
//  Created by samsam on 7/25/25.
//

import SwiftUI
import Combine
import AltSourceKit
import NimbleViews
import CoreData

struct DownloadButtonView: View {
	let app: ASRepository.App
	var title: String = .localized("Get")

	@ObservedObject private var downloadManager = DownloadManager.shared
	@Environment(\.colorScheme) private var colorScheme

	@State private var downloadProgress: Double = 0
	@State private var cancellable: AnyCancellable?
	@State private var zagPhase: ZagGetPhase = .idle
	@State private var installTarget: AnyApp?
	@State private var transactionError: String?

	private var pillBackground: Color {
		colorScheme == .dark
			? Color(hex: "#1C1C1E")
			: Color(hex: "#F2F2F7")
	}

	@AppStorage("Feather.userTintColor")
	private var userTintColor: String = "#4395F8"

	private var pillForeground: Color {
		Color(hex: userTintColor)
	}

	var body: some View {
		ZStack {
			if let currentDownload = downloadManager.getDownload(
				by: app.currentUniqueId
			) {
				ZStack {
					Circle()
						.trim(
							from: 0,
							to: downloadProgress
						)
						.stroke(
							pillForeground,
							style: StrokeStyle(
								lineWidth: 2.3,
								lineCap: .round
							)
						)
						.rotationEffect(.degrees(-90))
						.frame(
							width: 31,
							height: 31
						)
						.animation(
							.smooth,
							value: downloadProgress
						)

					Image(
						systemName:
							downloadProgress >= 0.75
							? "archivebox"
							: "square.fill"
					)
					.foregroundStyle(pillForeground)
					.font(.footnote)
					.bold()
				}
				.onTapGesture {
					if downloadProgress <= 0.75 {
						downloadManager.cancelDownload(
							currentDownload
						)
					}
				}
				.compatTransition()
			} else if zagPhase != .idle {
				ProgressView().frame(width: 88, height: 34)
			} else {
				Button {
					_startGetAndInstall()
				} label: {
					Text(title)
						.font(
							.system(
								size: 15,
								weight: .bold
							)
						)
						.lineLimit(1)
						.frame(
							width: 88,
							height: 34
						)
						.foregroundStyle(
							pillForeground
						)
						.background(
							pillBackground
						)
						.clipShape(Capsule())
						.contentShape(Capsule())
				}
				.buttonStyle(.borderless)
				.compatTransition()
			}
		}
		.onAppear(
			perform: setupObserver
		)
		.onDisappear {
			cancellable?.cancel()
		}
		.fullScreenCover(item: $installTarget) { target in
			InstallPreviewView(
				app: target.base,
				onInstallCompleted: {
					zagPhase = .idle
				}
			)
		}
		.alert(.localized("Unable to Install"), isPresented: Binding(
			get: { transactionError != nil },
			set: { if !$0 { transactionError = nil } }
		)) {
			Button(.localized("OK"), role: .cancel) {}
		} message: {
			Text(transactionError ?? "")
		}
		.onChange(
			of: downloadManager.downloads.description
		) { _ in
			setupObserver()
		}
		.animation(
			.easeInOut(duration: 0.3),
			value:
				downloadManager.getDownload(
					by: app.currentUniqueId
				) != nil
		)
	}

	private func _startGetAndInstall() {
		guard zagPhase == .idle, let url = app.currentDownloadUrl else { return }
		zagPhase = .downloading

		_ = downloadManager.startDownload(
			from: url,
			id: app.currentUniqueId,
			zagImported: { uuid, error in
				DispatchQueue.main.async {
					if let error {
						if (error as? URLError)?.code == .cancelled {
							zagPhase = .idle
						} else {
							_failTransaction(error.localizedDescription)
						}
						return
					}
					guard let uuid, let imported = _importedApp(uuid: uuid) else {
						_failTransaction(.localized("The downloaded app was imported, but Zag Store could not locate it for signing."))
						return
					}
					_signAndInstall(imported)
				}
			}
		)
	}

	private func _signAndInstall(_ imported: Imported) {
		zagPhase = .signing
		var options = OptionsManager.shared.options
		let selectedIndex = UserDefaults.standard.integer(forKey: "feather.selectedCert")
		let certificate = Storage.shared.getCertificate(for: selectedIndex)

		if options.signingOption == .default, certificate == nil {
			_failTransaction(.localized("The app was downloaded and kept in Imported, but no signing certificate is selected."))
			return
		}

		if
			options.ppqProtection,
			let identifier = imported.identifier,
			let certificate,
			certificate.ppQCheck
		{
			options.appIdentifier = "\(identifier).\(options.ppqString)"
		}
		if
			let identifier = imported.identifier,
			let mappedIdentifier = options.identifiers[identifier]
		{
			options.appIdentifier = mappedIdentifier
		}
		if
			let name = imported.name,
			let mappedName = options.displayNames[name]
		{
			options.appName = mappedName
		}

		var signedUUID: String?
		FR.signPackageFile(
			imported,
			using: options,
			icon: nil,
			certificate: certificate,
			signedUUID: { signedUUID = $0 }
		) { error in
			if let error {
				_failTransaction(error.localizedDescription)
				return
			}
			guard let signedUUID, let signed = _signedApp(uuid: signedUUID) else {
				_failTransaction(.localized("Signing completed, but Zag Store could not locate the signed app."))
				return
			}
			zagPhase = .installing
			installTarget = AnyApp(base: signed)
		}
	}

	private func _importedApp(uuid: String) -> Imported? {
		let request = NSFetchRequest<Imported>(entityName: "Imported")
		request.fetchLimit = 1
		request.predicate = NSPredicate(format: "uuid == %@", uuid)
		return try? Storage.shared.context.fetch(request).first
	}

	private func _signedApp(uuid: String) -> Signed? {
		let request = NSFetchRequest<Signed>(entityName: "Signed")
		request.fetchLimit = 1
		request.predicate = NSPredicate(format: "uuid == %@", uuid)
		return try? Storage.shared.context.fetch(request).first
	}

	private func _failTransaction(_ message: String) {
		zagPhase = .idle
		transactionError = message
	}

	private func setupObserver() {
		cancellable?.cancel()

		guard let download = downloadManager.getDownload(
			by: app.currentUniqueId
		) else {
			downloadProgress = 0
			return
		}

		downloadProgress = download.overallProgress

		let publisher = Publishers.CombineLatest(
			download.$progress,
			download.$unpackageProgress
		)

		cancellable = publisher.sink { _, _ in
			downloadProgress =
				download.overallProgress
		}
	}
	private enum ZagGetPhase {
		case idle
		case downloading
		case signing
		case installing
	}

}
