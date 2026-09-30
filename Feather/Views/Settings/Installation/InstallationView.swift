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

	var body: some View {
		Section {
			LabeledContent {
				Text("Experimental")
					.foregroundStyle(.orange)
			} label: {
				Label("RPPairing", systemImage: "iphone.radiowaves.left.and.right")
			}

			HStack(spacing: 10) {
				Image(systemName: "checkmark.circle.fill")
					.foregroundStyle(.green)
				Text("No computer-generated pairing file")
			}

			HStack(spacing: 10) {
				Image(systemName: "network")
					.foregroundStyle(.secondary)
				Text("On-device Remote Pairing")
			}
		} footer: {
			Text("The RPPairing engine is being integrated. This option will create and store its own Remote Pairing credentials on this iPhone, then use LocalDevVPN to reach Apple's device services for direct installation.")
		}

		Section {
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
		.onAppear {
			if let url = URL(string: "localdevvpn://") {
				isLocalDevVpnAvailable = UIApplication.shared.canOpenURL(url)
			}
		}
	}
}
