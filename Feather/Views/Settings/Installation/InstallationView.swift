//
//  InstallationView.swift
//  Feather
//
//  Created by samara on 3.06.2025.
//

import SwiftUI
import NimbleViews
import UniformTypeIdentifiers

// MARK: - View
struct InstallationView: View {
	@AppStorage("Feather.installationMethod") private var _installationMethod: Int = 0
	@State private var _showMethodChangedAlert = false

	private let _installationMethods: [String] = [
		.localized("Server"),
		.localized("idevice"),
		"RPPairing"
	]
	
	// MARK: Body
	var body: some View {
		NBList(.localized("Installation")) {
			Section {
				Picker(.localized("Installation Type"), systemImage: "arrow.down.app", selection: $_installationMethod) {
					ForEach(_installationMethods.indices, id: \.description) { index in
						Text(_installationMethods[index]).tag(index)
					}
				}
			} footer: {
				Text(.localized("Server (Recommended):\nUses a locally hosted server and itms-services:// to install applications.\n\nIDevice (advanced):\nUses a VPN and a pairing file. Writes to AFC and manually calls installd, while monitoring install progress by using a callback\nAdvantage: It is very reliable, does not need SSL certificates or a externally hosted server. Rather, works similarly to a computer.\n\nRPPairing (Experimental):\nPairs directly on-device using Apple's Remote Pairing protocol. No computer-generated pairing file is required. LocalDevVPN is still required for the direct device-services connection."))
			}
			
			if _installationMethod == 0 {
				ServerView()
			} else if _installationMethod == 1 {
				TunnelView()
			} else if _installationMethod == 2 {
				RPPairingView()
			}
		}
		.onChange(of: _installationMethod) { newValue in
			guard newValue == 1 else { return }
			_showMethodChangedAlert = true
		}
		.alert(.localized("Advanced Installation Method"), isPresented: $_showMethodChangedAlert) {
			Button(.localized("Switch Back"), role: .destructive) {
				_installationMethod = 0
			}
			Button(.localized("OK"), role: .cancel) {}
		} message: {
			Text(.localized("idevice warning"))
		}


		.animation(.default, value: _installationMethod)
	}
}



private struct RPPairingView: View {
	@State private var isLocalDevVpnAvailable = true
	@StateObject private var pairingCore = ZagRPPairingCore.shared
	@State private var showGate4Importer = false
	@State private var showUnpairConfirmation = false
	@State private var unpairError: String?

	var body: some View {
		Section {
			VStack(spacing: 0) {
				directStatusRow(
					"Pairing",
					value: pairingCore.pairingFileExists ? "Paired" : "Setup Required",
					systemImage: pairingCore.pairingFileExists ? "checkmark.circle.fill" : "exclamationmark.circle",
					color: pairingCore.pairingFileExists ? .green : .orange
				)
				Divider()
				directStatusRow(
					"Local Tunnel",
					value: tunnelStatusText,
					systemImage: tunnelStatusIcon,
					color: tunnelStatusColor
				)
				Divider()
				directStatusRow(
					"Direct Install",
					value: directInstallStatusText,
					systemImage: directInstallStatusIcon,
					color: directInstallStatusColor
				)
			}
			.listRowInsets(EdgeInsets())
		} header: {
			Text("Direct Install Status")
		} footer: {
			Text("RPPairing installs directly through this iPhone's device services. Run Health Check to verify the LocalDevVPN tunnel and complete direct-install path.")
		}

		Section {
			LabeledContent {
				Text(pairingCore.pairingFileExists ? "Ready" : "Setup Required")
					.foregroundStyle(pairingCore.pairingFileExists ? .green : .orange)
			} label: {
				Label("RPPairing", systemImage: "iphone.radiowaves.left.and.right")
			}

			HStack(spacing: 10) {
				Image(systemName: pairingCore.pairingFileExists ? "checkmark.circle.fill" : "circle")
					.foregroundStyle(pairingCore.pairingFileExists ? .green : .secondary)
				Text(pairingCore.pairingFileExists ? "Pairing credentials saved" : "No computer-generated pairing file")
			}

			HStack(spacing: 10) {
				Image(systemName: statusIcon)
					.foregroundStyle(statusColor)
				Text(statusText)
			}

			if case .pin(let pin) = pairingCore.state {
				VStack(spacing: 5) {
					Text("PAIRING CODE")
						.font(.caption.weight(.semibold))
						.foregroundStyle(.secondary)
					Text(pin)
						.font(.system(size: 32, weight: .semibold, design: .monospaced))
						.textSelection(.enabled)
				}
				.frame(maxWidth: .infinity)
				.padding(.vertical, 8)
			}

			if case .failed(let error) = pairingCore.state {
				Text(error)
					.font(.footnote)
					.foregroundStyle(.red)
					.textSelection(.enabled)
			}

			if case .paired(let name, let model, _) = pairingCore.state {
				LabeledContent("Paired Device") {
					VStack(alignment: .trailing, spacing: 2) {
						Text(name)
						if !model.isEmpty {
							Text(model)
								.font(.caption)
								.foregroundStyle(.secondary)
						}
					}
				}
			}

			Button(role: pairingCore.pairingFileExists ? .destructive : nil) {
				if pairingCore.pairingFileExists {
					showUnpairConfirmation = true
				} else {
					pairingCore.start()
				}
			} label: {
				HStack(spacing: 10) {
					ZStack {
						Image(systemName: "link")
						if pairingCore.pairingFileExists {
							Image(systemName: "minus.circle.fill")
								.font(.system(size: 9, weight: .bold))
								.background(Circle().fill(Color(.systemBackground)).padding(-1))
								.offset(x: 8, y: 7)
						} else if pairingCore.isRunning {
							Image(systemName: "antenna.radiowaves.left.and.right")
						} else {
							Image(systemName: "plus.circle.fill")
								.font(.system(size: 9, weight: .bold))
								.background(Circle().fill(Color(.systemBackground)).padding(-1))
								.offset(x: 8, y: 7)
						}
					}
					.frame(width: 22)
					Text(
						pairingCore.pairingFileExists
							? "Unpair This iPhone"
							: (pairingCore.isRunning ? "Waiting for This iPhone…" : "Pair This iPhone")
					)
					Spacer(minLength: 0)
				}
				.contentShape(Rectangle())
				.frame(maxWidth: .infinity, alignment: .leading)
			}
			.buttonStyle(.plain)
			.foregroundStyle(pairingCore.pairingFileExists ? Color.red : Color.accentColor)
			.frame(maxWidth: .infinity, alignment: .leading)
			.contentShape(Rectangle())
			.disabled(pairingCore.isRunning)
			.popover(isPresented: $showUnpairConfirmation, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
				ZagUnpairConfirmationBubble(
					confirm: {
						showUnpairConfirmation = false
						do { try pairingCore.forgetPairing() }
						catch { unpairError = error.localizedDescription }
					},
					cancel: { showUnpairConfirmation = false }
				)
				.frame(width: 340)
				.presentationCompactAdaptation(.popover)
			}
		} footer: {
			Text("Zag Store can now run the iOS 27 Remote Pairing host directly on-device. Start pairing here; when iOS connects, Zag Store will display the six-digit code and save the resulting credentials locally.")
		}

		Section("Setup") {
			if isLocalDevVpnAvailable {
				Button("Connect to LocalDevVPN", systemImage: "link") {
					UIApplication.open("localdevvpn://enable?scheme=feather")
				}
			} else {
				Button("Download LocalDevVPN", systemImage: "arrow.down.app") {
					UIApplication.open("https://apps.apple.com/us/app/localdevvpn/id6755608044")
				}
			}
	

		}

		Section {
			NavigationLink {
				RPPairingDiagnosticsView()
			} label: {
				Label("Diagnostics & Health Checks", systemImage: "stethoscope")
			}
		} header: {
			Text("Diagnostics")
		} footer: {
			Text("Run the complete RPPairing health check, inspect every device-service stage, and access the controlled installation test.")
		}


		.alert("Unable to Unpair", isPresented: Binding(
			get: { unpairError != nil },
			set: { if !$0 { unpairError = nil } }
		)) {
			Button("OK", role: .cancel) { unpairError = nil }
		} message: {
			Text(unpairError ?? "")
		}


		.fileImporter(
			isPresented: $showGate4Importer,
			allowedContentTypes: [.data],
			allowsMultipleSelection: false
		) { result in
			switch result {
			case .success(let urls):
				guard let url = urls.first else { return }
				do {
					try pairingCore.installGate4IPA(at: url)
				} catch {
					// Copy/import errors are surfaced here; transport/install errors
					// are reported by the Gate 4 callback state.
					print("Gate 4 IPA import failed: \(error)")
				}
			case .failure(let error):
				print("Gate 4 file importer failed: \(error)")
			}
		}
	}

	private var tunnelVerified: Bool {
		switch pairingCore.gate2State {
		case .lockdown, .pairing, .pairRecord, .coreDevice, .rsd, .deviceInfo, .installationProxy, .installedApps, .afc, .stagingWrite, .stagingVerify, .complete:
			return true
		default:
			return false
		}
	}

	private var tunnelStatusText: String {
		if tunnelVerified { return "Connected" }
		if pairingCore.isGate2Running { return "Checking…" }
		return "Run Health Check"
	}

	private var tunnelStatusIcon: String {
		tunnelVerified ? "checkmark.circle.fill" : (pairingCore.isGate2Running ? "circle.dotted" : "network")
	}

	private var tunnelStatusColor: Color {
		tunnelVerified ? .green : .secondary
	}

	private var directInstallStatusText: String {
		pairingCore.pairingFileExists && tunnelVerified ? "Ready" : "Check Required"
	}

	private var directInstallStatusIcon: String {
		pairingCore.pairingFileExists && tunnelVerified ? "checkmark.circle.fill" : "circle"
	}

	private var directInstallStatusColor: Color {
		pairingCore.pairingFileExists && tunnelVerified ? .green : .secondary
	}

	@ViewBuilder
	private func directStatusRow(_ title: String, value: String, systemImage: String, color: Color) -> some View {
		HStack(spacing: 12) {
			Text(title)
			Spacer()
			Label(value, systemImage: systemImage)
				.foregroundStyle(color)
		}
		.padding(.horizontal, 16)
		.frame(minHeight: 50)
	}

	private var statusText: String {
		switch pairingCore.state {
		case .idle:
			return "Ready for on-device Remote Pairing"
		case .starting:
			return "Starting pairing host…"
		case .advertising:
			return "Advertising — waiting for this iPhone"
		case .connected:
			return "This iPhone connected"
		case .pin:
			return "Enter the code when iOS asks"
		case .paired:
			return "Remote Pairing complete"
		case .failed:
			return "Remote Pairing failed"
		}
	}

	private var statusIcon: String {
		switch pairingCore.state {
		case .paired:
			return "checkmark.circle.fill"
		case .failed:
			return "exclamationmark.triangle.fill"
		case .starting, .advertising, .connected, .pin:
			return "antenna.radiowaves.left.and.right"
		case .idle:
			return "network"
		}
	}

	private var statusColor: Color {
		switch pairingCore.state {
		case .paired:
			return .green
		case .failed:
			return .red
		default:
			return .secondary
		}
	}
}


private struct ZagUnpairConfirmationBubble: View {
	let confirm: () -> Void
	let cancel: () -> Void

	var body: some View {
		VStack(spacing: 0) {
			VStack(alignment: .leading, spacing: 10) {
				Text("Unpair This iPhone?")
					.font(.title3.weight(.semibold))
				Text("This removes Zag Store's saved RPPairing credentials. You will need to pair again before direct installation can be used.")
					.font(.body)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.horizontal, 20)
			.padding(.top, 18)
			.padding(.bottom, 14)

			Divider()

			Button(role: .destructive, action: confirm) {
				Text("Unpair This iPhone")
					.font(.body.weight(.semibold))
					.frame(maxWidth: .infinity)
					.frame(minHeight: 50)
			}
			.buttonStyle(.plain)
			.foregroundStyle(.red)

			Divider()

			Button(action: cancel) {
				Text("Cancel")
					.font(.body.weight(.semibold))
					.frame(maxWidth: .infinity)
					.frame(minHeight: 50)
			}
			.buttonStyle(.plain)
			.foregroundStyle(Color.accentColor)
		}
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
		.overlay {
			RoundedRectangle(cornerRadius: 28, style: .continuous)
				.strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
		}
		.overlay(alignment: .bottom) {
			Image(systemName: "triangle.fill")
				.font(.system(size: 24))
				.foregroundStyle(.regularMaterial)
				.rotationEffect(.degrees(180))
				.offset(y: 15)
		}
		.shadow(color: .black.opacity(0.28), radius: 24, y: 10)
		.frame(maxWidth: .infinity)
		.padding(.horizontal, 2)
	}
}

struct RPPairingDiagnosticsView: View {
	@StateObject private var pairingCore = ZagRPPairingCore.shared
	@State private var showGate4Importer = false
	@State private var healthMessage: String?

	var body: some View {
		NBList("Diagnostics") {
			Section {
				gate2Row("Pairing Credentials", complete: pairingCore.pairingFileExists)
				gate2Row("LocalDevVPN / RPPairing", stage: .lockdown)
				gate2Row("RPPairing Pair-Verify", stage: .pairRecord)
				gate2Row("TLS-PSK Device Tunnel", stage: .coreDevice)
				gate2Row("RSD", stage: .rsd)
				gate2Row("Installation Proxy", stage: .installationProxy)
				gate2Row("Installed Apps Lookup", stage: .installedApps)
				gate2Row("AFC", stage: .afc)
				gate2Row("PublicStaging Write", stage: .stagingWrite)
				gate2Row("PublicStaging Verify", stage: .stagingVerify)
				gate2Row("Cleanup", stage: .cleanup)

				if case .complete(let name, let model, let version, let build, let userAppCount, let zagStoreFound) = pairingCore.gate2State {
					LabeledContent("Device") {
						VStack(alignment: .trailing, spacing: 2) {
							Text(name)
							if !model.isEmpty { Text(model).font(.caption).foregroundStyle(.secondary) }
							if !version.isEmpty { Text("iOS \(version)\(build.isEmpty ? "" : " (\(build))")").font(.caption).foregroundStyle(.secondary) }
						}
					}
					LabeledContent("User Apps") { Text("\(userAppCount)") }
					LabeledContent("Zag Store") {
						Label(zagStoreFound ? "Found" : "Not Found", systemImage: zagStoreFound ? "checkmark.circle.fill" : "exclamationmark.circle")
							.foregroundStyle(zagStoreFound ? .green : .orange)
					}
				}

				if case .failed(let error) = pairingCore.gate2State {
					Text(error).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
				}

				Button {
					guard pairingCore.pairingFileExists else {
						healthMessage = "Pair this iPhone first. The full health check needs saved RPPairing credentials before it can test LocalDevVPN, Pair-Verify, RSD, Installation Proxy and AFC."
						return
					}
					pairingCore.startGate2Probe()
				} label: {
					Label(pairingCore.isGate2Running ? "Running Health Check…" : "Run Full Health Check", systemImage: pairingCore.isGate2Running ? "wave.3.right" : "stethoscope")
				}
				.disabled(pairingCore.isGate2Running)
			} header: {
				Text("Health Checks")
			} footer: {
				Text("Connect LocalDevVPN first. This verifies pairing, Pair-Verify, TLS-PSK, RSD, Installation Proxy, app lookup, and AFC/PublicStaging write-read-cleanup.")
			}

			Section {
				LabeledContent("Status") { Text(gate4StatusText).foregroundStyle(gate4StatusColor) }
				if case .progress(let percent) = pairingCore.gate4State {
					ProgressView(value: Double(percent), total: 100) { Text("Installing") } currentValueLabel: { Text("\(percent)%") }
				}
				if case .failed(let error) = pairingCore.gate4State {
					Text(error).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
				}
				Button {
					showGate4Importer = true
				} label: {
					Label("Run Installation Test…", systemImage: "shippingbox")
				}
				.disabled(pairingCore.isGate4Running || !pairingCore.pairingFileExists)
			} header: {
				Text("Installation Test")
			} footer: {
				Text("Runs the complete direct-install path with a signed disposable IPA. Do not select Zag Store itself.")
			}
		}
		.alert("Health Check", isPresented: Binding(
			get: { healthMessage != nil },
			set: { if !$0 { healthMessage = nil } }
		)) {
			Button("OK", role: .cancel) { healthMessage = nil }
		} message: {
			Text(healthMessage ?? "")
		}
		.fileImporter(isPresented: $showGate4Importer, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
			switch result {
			case .success(let urls):
				guard let url = urls.first else { return }
				do { try pairingCore.installGate4IPA(at: url) }
				catch { print("Gate 4 IPA import failed: \(error)") }
			case .failure(let error):
				print("Gate 4 file importer failed: \(error)")
			}
		}
	}

	private var gate4StatusText: String {
		switch pairingCore.gate4State {
		case .idle: return "Ready for installation test"
		case .starting: return "Starting RPPairing…"
		case .pairVerified: return "Pair-Verify complete"
		case .tunnel: return "TLS-PSK tunnel established"
		case .rsd: return "RSD established"
		case .installing: return "Staging and installing…"
		case .progress(let percent): return "Installing — \(percent)%"
		case .complete: return "Installation complete"
		case .failed: return "Installation failed"
		}
	}

	private var gate4StatusColor: Color {
		switch pairingCore.gate4State {
		case .complete: return .green
		case .failed: return .red
		default: return .secondary
		}
	}

	private enum Gate2Stage {
		case lockdown
		case pairRecord
		case coreDevice
		case rsd
		case installationProxy
		case installedApps
		case afc
		case stagingWrite
		case stagingVerify
		case cleanup
	}

	@ViewBuilder
	private func gate2Row(_ title: String, complete: Bool) -> some View {
		HStack(spacing: 10) {
			Image(systemName: complete ? "checkmark.circle.fill" : "circle")
				.foregroundStyle(complete ? .green : .secondary)
			Text(title)
		}
	}

	@ViewBuilder
	private func gate2Row(_ title: String, stage: Gate2Stage) -> some View {
		let status = gate2Status(for: stage)
		HStack(spacing: 10) {
			Image(systemName: status.icon)
				.foregroundStyle(status.color)
			Text(title)
			Spacer()
			if status.active {
				ProgressView()
					.controlSize(.small)
			}
		}
	}

	private func gate2Status(for stage: Gate2Stage) -> (icon: String, color: Color, active: Bool) {
		let rank: Int
		let failed: Bool
		switch pairingCore.gate2State {
		case .idle: rank = 0; failed = false
		case .starting: rank = 0; failed = false
		case .lockdown: rank = 1; failed = false
		case .pairing: rank = 1; failed = false
		case .pairRecord: rank = 2; failed = false
		case .coreDevice: rank = 3; failed = false
		case .rsd: rank = 4; failed = false
		case .deviceInfo: rank = 5; failed = false
		case .installationProxy: rank = 5; failed = false
		case .installedApps: rank = 6; failed = false
		case .afc: rank = 7; failed = false
		case .stagingWrite: rank = 8; failed = false
		case .stagingVerify: rank = 9; failed = false
		case .complete: rank = 11; failed = false
		case .failed: rank = -1; failed = true
		}

		let target: Int
		switch stage {
		case .lockdown: target = 1
		case .pairRecord: target = 2
		case .coreDevice: target = 3
		case .rsd: target = 4
		case .installationProxy: target = 5
		case .installedApps: target = 6
		case .afc: target = 7
		case .stagingWrite: target = 8
		case .stagingVerify: target = 9
		case .cleanup: target = 10
		}

		if rank > target || rank == 11 {
			return ("checkmark.circle.fill", .green, false)
		}
		if rank == target {
			return ("circle.dotted", .secondary, true)
		}
		if failed {
			return ("exclamationmark.circle", .red, false)
		}
		return ("circle", .secondary, false)
	}

}

