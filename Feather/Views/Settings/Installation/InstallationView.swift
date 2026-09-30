//
//  InstallationView.swift
//  Feather
//
//  Created by samara on 3.06.2025.
//

import SwiftUI
import NimbleViews

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
	@State private var isLocalDevVpnAvailable = false
	@StateObject private var pairingCore = ZagRPPairingCore.shared

	var body: some View {
		Section {
			LabeledContent {
				Text("Experimental")
					.foregroundStyle(.orange)
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

			Button {
				pairingCore.start()
			} label: {
				Label(
					pairingCore.isRunning ? "Waiting for This iPhone…" : "Pair This iPhone",
					systemImage: pairingCore.isRunning ? "antenna.radiowaves.left.and.right" : "link.badge.plus"
				)
			}
			.disabled(pairingCore.isRunning)
		} footer: {
			Text("Zag Store can now run the iOS 27 Remote Pairing host directly on-device. Start pairing here; when iOS connects, Zag Store will display the six-digit code and save the resulting credentials locally.")
		}

		Section("Local Device Tunnel") {
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
			gate2Row("Pairing Credentials", complete: pairingCore.pairingFileExists)
			gate2Row("LocalDevVPN / RPPairing", stage: .lockdown)
			gate2Row("RPPairing Pair-Verify", stage: .pairRecord)
			gate2Row("TLS-PSK Device Tunnel", stage: .coreDevice)
			gate2Row("RSD", stage: .rsd)

			if case .complete(let name, let model, let version, let build) = pairingCore.gate2State {
				LabeledContent("Device") {
					VStack(alignment: .trailing, spacing: 2) {
						Text(name)
						if !model.isEmpty {
							Text(model)
								.font(.caption)
								.foregroundStyle(.secondary)
						}
						if !version.isEmpty {
							Text("iOS \(version)\(build.isEmpty ? "" : " (\(build))")")
								.font(.caption)
								.foregroundStyle(.secondary)
						}
					}
				}
			}

			if case .failed(let error) = pairingCore.gate2State {
				Text(error)
					.font(.footnote)
					.foregroundStyle(.red)
					.textSelection(.enabled)
			}

			Button {
				pairingCore.startGate2Probe()
			} label: {
				Label(
					pairingCore.isGate2Running ? "Testing Device Connection…" : "Test Device Connection",
					systemImage: pairingCore.isGate2Running ? "wave.3.right" : "stethoscope"
				)
			}
			.disabled(pairingCore.isGate2Running || !pairingCore.pairingFileExists)
		} header: {
			Text("Gate 2 — Device Services")
		} footer: {
			Text("Connect LocalDevVPN first. This diagnostic reuses the RPPairing credentials already created on this iPhone, verifies them through LocalDevVPN, then tests the TLS-PSK device tunnel and RSD. It does not create a classic pair record and does not install, remove, or modify apps.")
		}
		.onAppear {
			if let url = URL(string: "localdevvpn://") {
				isLocalDevVpnAvailable = UIApplication.shared.canOpenURL(url)
			}
		}
	}

	private enum Gate2Stage {
		case lockdown
		case pairRecord
		case coreDevice
		case rsd
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
		case .complete: rank = 5; failed = false
		case .failed: rank = -1; failed = true
		}

		let target: Int
		switch stage {
		case .lockdown: target = 1
		case .pairRecord: target = 2
		case .coreDevice: target = 3
		case .rsd: target = 4
		}

		if rank > target || rank == 5 {
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
