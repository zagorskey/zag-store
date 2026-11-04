//
//  InstallPreview.swift
//  Feather
//
//  Created by samara on 22.04.2025.
//

import SwiftUI
import NimbleViews
import IDeviceSwift
import OSLog

// MARK: - View
struct InstallPreviewView: View {
	@Environment(\.dismiss) var dismiss

	@AppStorage("Feather.useShareSheetForArchiving") private var _useShareSheet: Bool = false
	// Transport is selected by platform, never by a stale persisted dropdown value.
    private var _installationMethod: Int {
        if #available(iOS 17.0, *) { return 2 }
        return 1
    }
	@State private var _didReportInstallSuccess = false
	
	var app: AppInfoPresentable
	@StateObject var viewModel: InstallerStatusViewModel
	
	@State var isSharing: Bool
	let onInstallCompleted: (() -> Void)?
	
	init(
		app: AppInfoPresentable,
		isSharing: Bool = false,
		onInstallCompleted: (() -> Void)? = nil
	) {
		self.app = app
		self.isSharing = isSharing
		self.onInstallCompleted = onInstallCompleted
		let viewModel = InstallerStatusViewModel(isIdevice: { if #available(iOS 17.0, *) { return false }; return true }())
		self._viewModel = StateObject(wrappedValue: viewModel)
	}
	
	// MARK: Body
	var body: some View {
		let cornerRadius = {
			if #available(iOS 26.0, *) {
				28.0
			} else {
				10.5
			}
		}()
		
		ZStack {
			InstallProgressView(app: app, viewModel: viewModel)
			_status()
			_button()
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
		.background(Color(UIColor.secondarySystemBackground))
		.cornerRadius(cornerRadius)
		.padding()
		.onReceive(viewModel.$status) { newStatus in
			if case .completed(.success(())) = newStatus {
				_reportInstallSuccessIfNeeded()
			}
		}
		.onAppear(perform: _install)
		
		#if !targetEnvironment(macCatalyst)
		.onAppear {
			BackgroundAudioManager.shared.start()
		}
		#endif
		
		.onDisappear {
			#if !targetEnvironment(macCatalyst)
			BackgroundAudioManager.shared.stop()
			#endif
		}
	}
	
	private func _reportInstallSuccessIfNeeded() {
		guard !_didReportInstallSuccess else { return }
		_didReportInstallSuccess = true
		onInstallCompleted?()
	}

	@ViewBuilder
	private func _status() -> some View {
		Label(viewModel.statusLabel, systemImage: viewModel.statusImage)
			.padding()
			.labelStyle(.titleAndIcon)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
			.animation(.smooth, value: viewModel.statusImage)
	}
	
	@ViewBuilder
	private func _button() -> some View {
		ZStack {
			if viewModel.isCompleted {
				Button {
					UIApplication.openApp(with: app.identifier ?? "")
				} label: {
					NBButton("Open", systemImage: "", style: .text)
				}
				.padding()
				.compatTransition()
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
		.animation(.easeInOut(duration: 0.3), value: viewModel.isCompleted)
	}
	
	private func _install() {
		guard isSharing || app.identifier != Bundle.main.bundleIdentifier! || _installationMethod == 1 else {
			UIAlertController.showAlertWithOk(
				title: .localized("Install"),
				message: .localized("You cannot update ‘%@‘ with itself, please use an alternative tool to update it.", arguments: Bundle.main.name)
			)
			return
		}
				
		Task.detached {
			do {
				let handler = await ArchiveHandler(app: app, viewModel: viewModel)
				try await handler.move()
				
				let packageUrl = try await handler.archive()
				
				if await !isSharing {
					if await _installationMethod == 1 {
						let handler = await InstallationProxy(viewModel: viewModel)
						try await handler.install(at: packageUrl, suspend: app.identifier == Bundle.main.bundleIdentifier!)
					} else if await _installationMethod == 2 {
						await MainActor.run {
							viewModel.status = .installing
						}

						try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
							Task { @MainActor in
								do {
									try ZagRPPairingCore.shared.installGate4IPA(
									at: packageUrl,
									deviceIP: ZagDeviceLink.peerAddress,
									retryTransientFailures: true,
									progress: { percent in
										viewModel.installProgress = Double(percent) / 100.0
									}
								) { result in
									switch result {
									case .success:
										viewModel.installProgress = 1.0
										viewModel.status = .completed(.success(()))
										continuation.resume()
									case .failure(let error):
										viewModel.status = .broken(error)
										continuation.resume(throwing: error)
									}
									}
								} catch {
									viewModel.status = .broken(error)
									continuation.resume(throwing: error)
								}
							}
						}
					}
				} else {
					let package = try await handler.moveToArchive(packageUrl, shouldOpen: !_useShareSheet)
					
					if await !_useShareSheet {
						await MainActor.run {
							dismiss()
						}
					} else {
						if let package {
							await MainActor.run {
								dismiss()
								UIActivityViewController.show(activityItems: [package])
							}
						}
					}
				}
			} catch {
				
				await MainActor.run {
					UIAlertController.showAlertWithOk(
						title: .localized("Install"),
						message: String(describing: error),
						action: {
							HeartbeatManager.shared.start(true)
							dismiss()
						}
					)
				}
			}
		}
	}
	
}
