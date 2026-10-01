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
import IDeviceSwift

struct DownloadButtonView: View {
	let app: ASRepository.App
	var title: String = .localized("Get")

	@ObservedObject private var downloadManager = DownloadManager.shared
	@Environment(\.colorScheme) private var colorScheme

	@State private var downloadProgress: Double = 0
	@State private var cancellable: AnyCancellable?
	@State private var zagPhase: ZagGetPhase = .idle
	@State private var installedBundleID: String?
	@State private var installationProgress: Double = 0
	@State private var transactionError: String?
	@State private var ringRotation: Double = 0

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
		VStack(spacing: 2) {
			ZStack {
				if let currentDownload = downloadManager.getDownload(by: app.currentUniqueId) {
					_progressRing(progress: downloadProgress, showsStop: downloadProgress < 0.75)
						.onTapGesture {
							if downloadProgress <= 0.75 {
								downloadManager.cancelDownload(currentDownload)
							}
						}
				} else if zagPhase == .signing {
					_indeterminateRing()
				} else if zagPhase == .installing {
					if installationProgress > 0.03 {
						_progressRing(progress: installationProgress, showsStop: false)
					} else {
						_indeterminateRing()
					}
				} else if let installedBundleID {
					ZagActionPill(title: .localized("Open")) {
						UIApplication.openApp(with: installedBundleID)
					}
				} else {
					ZagActionPill(title: title) {
						_startGetAndInstall()
					}
				}
			}
			.frame(width: 88, height: 34)

			Text(_stageCaption)
				.font(.system(size: 9, weight: .medium))
				.foregroundStyle(.secondary)
				.lineLimit(1)
				.frame(width: 88, height: 11)
				.opacity(_stageCaption.isEmpty ? 0 : 1)
		}
		.onAppear(perform: setupObserver)
		.onDisappear { cancellable?.cancel() }
		.alert(.localized("Unable to Install"), isPresented: Binding(
			get: { transactionError != nil },
			set: { if !$0 { transactionError = nil } }
		)) {
			Button(.localized("OK"), role: .cancel) {}
		} message: {
			Text(transactionError ?? "")
		}
		.onChange(of: downloadManager.downloads.description) { _ in
			setupObserver()
		}
		.animation(.easeInOut(duration: 0.25), value: zagPhase)
	}

	private var _stageCaption: String {
		switch zagPhase {
		case .signing: return .localized("Preparing…")
		case .installing: return .localized("Installing…")
		default: return ""
		}
	}

	private func _indeterminateRing() -> some View {
		ZStack {
			Circle()
				.stroke(pillForeground.opacity(0.22), lineWidth: 2.3)
			Circle()
				.trim(from: 0.08, to: 0.72)
				.stroke(pillForeground, style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
				.rotationEffect(.degrees(ringRotation - 90))
		}
		.frame(width: 31, height: 31)
		.onAppear {
			ringRotation = 0
			withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
				ringRotation = 360
			}
		}
	}

	@ViewBuilder
	private func _progressRing(progress: Double, showsStop: Bool) -> some View {
		ZStack {
			Circle()
				.stroke(pillForeground.opacity(0.22), lineWidth: 2.3)
			Circle()
				.trim(from: 0, to: max(0.03, min(1, progress)))
				.stroke(pillForeground, style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
				.rotationEffect(.degrees(-90))
			if showsStop {
				Image(systemName: "square.fill")
					.foregroundStyle(pillForeground)
					.font(.footnote)
			} else if progress >= 1 {
				Image(systemName: "checkmark")
					.foregroundStyle(pillForeground)
					.font(.footnote.bold())
			}
		}
		.frame(width: 31, height: 31)
		.animation(.smooth, value: progress)
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
			installationProgress = 0
			_installInline(signed)
		}
	}

	private func _installInline(_ signed: Signed) {
		let method = UserDefaults.standard.integer(forKey: "Feather.installationMethod")
		let serverMethod = UserDefaults.standard.integer(forKey: "Feather.serverMethod")

		Task {
			do {
				let status = InstallerStatusViewModel(isIdevice: method == 1)
				let archive = ArchiveHandler(app: signed, viewModel: status)
				try await archive.move()
				let packageURL = try await archive.archive()

				if method == 0 {
					guard serverMethod == 0 else {
						throw ZagInlineInstallError.semiLocalRequiresPreview
					}
					let server = try ServerInstaller(app: signed, viewModel: status)
					server.packageUrl = packageURL
					status.status = .ready
					guard let installURL = URL(string: server.iTunesLink) else {
						throw ZagInlineInstallError.invalidInstallURL
					}
					await UIApplication.shared.open(installURL)
					try await _pollInstall(bundleID: signed.identifier ?? "")
				} else if method == 1 {
					let proxy = InstallationProxy(viewModel: status)
					try await proxy.install(at: packageURL, suspend: false)
					installationProgress = 1
				} else {
					try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
						do {
							try ZagRPPairingCore.shared.installGate4IPA(
								at: packageURL,
								deviceIP: "10.7.0.1",
								progress: { percent in
									installationProgress = Double(percent) / 100.0
								}
							) { result in
								switch result {
								case .success: continuation.resume()
								case .failure(let error): continuation.resume(throwing: error)
								}
							}
							} catch {
								continuation.resume(throwing: error)
							}
						}
					installationProgress = 1
				}

				installedBundleID = signed.identifier
				zagPhase = .idle
			} catch {
				_failTransaction(error.localizedDescription)
			}
		}
	}

	private func _pollInstall(bundleID: String) async throws {
		guard !bundleID.isEmpty else { throw ZagInlineInstallError.missingBundleIdentifier }
		var started = false
		for _ in 0..<600 {
			let raw = UIApplication.installProgress(for: bundleID) ?? 0
			if raw > 0 { started = true }
			if started {
				installationProgress = min(1, max(0.03, (raw - 0.6) / 0.3))
				if raw == 0 {
					installationProgress = 1
					return
				}
			}
			try await Task.sleep(nanoseconds: 100_000_000)
		}
		throw ZagInlineInstallError.installTimedOut
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

	private enum ZagInlineInstallError: LocalizedError {
		case semiLocalRequiresPreview
		case invalidInstallURL
		case missingBundleIdentifier
		case installTimedOut

		var errorDescription: String? {
			switch self {
			case .semiLocalRequiresPreview: return "Semi Local installation still requires the installation preview. Choose Fully Local, idevice, or RPPairing for inline repository installs."
			case .invalidInstallURL: return "Zag Store could not create the local installation URL."
			case .missingBundleIdentifier: return "The signed app has no bundle identifier."
			case .installTimedOut: return "Zag Store could not confirm that installation completed."
			}
		}
	}

}
