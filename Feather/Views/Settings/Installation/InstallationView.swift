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
    @AppStorage("Feather.userTintColor") private var themeColorHex = "#0090FF"
    // The legacy transport remains available for older iOS versions.
    // The installation dispatcher must use the same platform rule.
    private var usesLegacyTransport: Bool {
        if #available(iOS 17.0, *) { return false }
        return true
    }

    var body: some View {
        NBList(.localized("Installation")) {
            if usesLegacyTransport {
                TunnelView()
            } else {
                RPPairingView()
            }
        }
        .tint(Color(hex: themeColorHex))
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 48)
        }
    }
}


private struct ZagInstallationTintedIconLabelStyle: LabelStyle {
    @AppStorage("Feather.userTintColor") private var themeColorHex = "#0090FF"

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
                .foregroundStyle(Color(hex: themeColorHex))
            configuration.title
                .foregroundStyle(.primary)
        }
    }
}

private struct RPPairingView: View {
	@State private var isLocalDevVpnAvailable = true
	@StateObject private var pairingCore = ZagRPPairingCore.shared
	@State private var showGate4Importer = false
	@State private var showUnpairConfirmation = false
	@State private var unpairError: String?
	@State private var pairingExportURL: URL?
	@State private var pairingExportError: String?
	@State private var pairingDocumentController: UIDocumentInteractionController?

	var body: some View {
		Section {
			directStatusRow(
				"Pairing",
				titleSystemImage: "iphone.radiowaves.left.and.right",
				value: pairingCore.pairingFileExists ? "Paired" : "Setup Required",
				systemImage: pairingCore.pairingFileExists ? "checkmark.circle.fill" : "exclamationmark.circle",
				color: pairingCore.pairingFileExists ? .green : .orange
			)

			Button {
				guard !tunnelVerified else { return }
				if isLocalDevVpnAvailable {
					UIApplication.open("localdevvpn://enable?scheme=feather")
				} else {
					UIApplication.open("https://apps.apple.com/us/app/localdevvpn/id6755608044")
				}
			} label: {
				directStatusRow(
					"LocalDevVPN",
					titleSystemImage: "network",
					value: tunnelVerified ? "Connected" : (isLocalDevVpnAvailable ? "Connect" : "Download"),
					systemImage: tunnelVerified ? "checkmark.circle.fill" : "link",
					color: tunnelVerified ? .green : .accentColor
				)
			}
			.buttonStyle(.plain)

			directStatusRow(
				"Installation",
				titleSystemImage: "arrow.down.app",
				value: directInstallStatusText,
				systemImage: directInstallStatusIcon,
				color: directInstallStatusColor
			)
		} header: {
			Text("Status")
		} footer: {
			Text("RPPairing requires pairing and a LocalDevVPN connection for direct installation.")
		}

		Section {
			HStack {
				Label("Pairing File", systemImage: "doc.badge.gearshape")
				Spacer()
				Text(pairingCore.pairingFileExists ? "Saved" : "Not Saved")
					.foregroundStyle(pairingCore.pairingFileExists ? .green : .secondary)
				Image(systemName: pairingCore.pairingFileExists ? "checkmark.circle.fill" : "circle")
					.foregroundStyle(pairingCore.pairingFileExists ? .green : .secondary)
					.frame(width: 22, alignment: .center)
			}

			if pairingCore.pairingFileExists {
				if let pairingExportURL {
					ShareLink(item: pairingExportURL) {
						Label("Export Pairing File", systemImage: "square.and.arrow.up")
					}
				} else {
					Button {
						do {
							pairingExportURL = try pairingCore.pairingFileForExport()
						} catch {
							pairingExportError = error.localizedDescription
						}
					} label: {
						Label("Export Pairing File", systemImage: "square.and.arrow.up")
					}
				}
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

			Button(role: pairingCore.pairingFileExists ? .destructive : nil) {
				if pairingCore.pairingFileExists {
					showUnpairConfirmation = true
				} else {
					pairingCore.start()
				}
			} label: {
				Label {
					Text(
						pairingCore.pairingFileExists
							? "Unpair This iPhone"
							: (pairingCore.isRunning ? "Waiting for This iPhone…" : "Pair This iPhone")
					)
				} icon: {
					if pairingCore.pairingFileExists {
						ZStack(alignment: .bottomTrailing) {
							Image(systemName: "iphone")
							Image(systemName: "minus.circle.fill")
								.font(.system(size: 9, weight: .bold))
								.background(Circle().fill(Color(uiColor: .systemBackground)).padding(1))
								.offset(x: 4, y: 3)
						}
					} else {
						Image(systemName: "iphone.radiowaves.left.and.right")
					}
				}
				.frame(maxWidth: .infinity, alignment: .leading)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.foregroundStyle(pairingCore.pairingFileExists ? Color.red : Color.accentColor)
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
		} header: {
			Text("Control")
		} footer: {
			Text("Pairing credentials are stored locally and reused for direct installation.")
		}

		Section {
			ZagMobileDataFixRow()
		} header: {
			Text("Mobile Data")
		} footer: {
			Text("Install over 4G or 5G by letting an Apple Shortcut turn Mobile Data off during the install.")
		}

		Section {
			NavigationLink {
				RPPairingDiagnosticsView()
                    .zagSettingsDestinationAvatar()
			} label: {
				Label("RPPairing Diagnostics", systemImage: "stethoscope")
			}
		} header: {
			Text("Diagnostics")
		} footer: {
			Text("Run the complete RPPairing health check, inspect every device-service stage, and access the controlled installation test.")
		}


		.alert("Unable to Export Pairing File", isPresented: Binding(
			get: { pairingExportError != nil },
			set: { if !$0 { pairingExportError = nil } }
		)) {
			Button("OK", role: .cancel) { pairingExportError = nil }
		} message: {
			Text(pairingExportError ?? "")
		}

		.alert("Unable to Unpair", isPresented: Binding(
			get: { unpairError != nil },
			set: { if !$0 { unpairError = nil } }
		)) {
			Button("OK", role: .cancel) { unpairError = nil }
		} message: {
			Text(unpairError ?? "")
		}


		.onAppear {
			if pairingCore.pairingFileExists &&
			   !pairingCore.isGate2Running &&
			   pairingCore.gate2State == .idle {
				pairingCore.startGate2Probe()
			}
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

	private func openPairingFileInAnotherApp(_ url: URL) {
		let controller = UIDocumentInteractionController(url: url)
		pairingDocumentController = controller

		guard let scene = UIApplication.shared.connectedScenes
			.compactMap({ $0 as? UIWindowScene })
			.first(where: { $0.activationState == .foregroundActive }),
			let window = scene.windows.first(where: { $0.isKeyWindow }),
			let rootView = window.rootViewController?.view
		else {
			pairingExportError = "Unable to present the app chooser."
			pairingDocumentController = nil
			return
		}

		if !controller.presentOpenInMenu(
			from: CGRect(x: rootView.bounds.midX, y: rootView.bounds.midY, width: 1, height: 1),
			in: rootView,
			animated: true
		) {
			pairingExportError = "No compatible app is available to open this pairing file."
			pairingDocumentController = nil
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
	private func directStatusRow(
		_ title: String,
		titleSystemImage: String,
		value: String,
		systemImage: String,
		color: Color
	) -> some View {
		HStack {
			Label(title, systemImage: titleSystemImage)
                .labelStyle(ZagInstallationTintedIconLabelStyle())
			Spacer()
			Text(value)
				.foregroundStyle(color)
			Image(systemName: systemImage)
				.foregroundStyle(color)
				.frame(width: 22, alignment: .center)
		}
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
	@FetchRequest(
		entity: Signed.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Signed.date, ascending: false)],
		animation: .snappy
	) private var signedApps: FetchedResults<Signed>

	@State private var showGate4SignedPicker = false
	@State private var showInstalledAppsInventory = false
	@State private var inventoryError: String?
	@State private var healthMessage: String?
	@State private var reportState: ReportState = .idle

	private enum ReportState { case idle, preparing, copied }
	@State private var traceState: ReportState = .idle
	@ObservedObject private var mobileDataToggle = ZagMobileDataToggleController.shared
	@ObservedObject private var mobileDataInstall = ZagMobileDataInstallCoordinator.shared
	@State private var toggleLogCopied = false
	@State private var traceSummary: [String] = []

	var body: some View {
		NBList("RPPairing Diagnostics") {
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

				Button {
					guard pairingCore.pairingFileExists else {
						healthMessage = "Pair this iPhone first."
						return
					}
					pairingCore.startGate2Probe(endpoint: .loopbackExperimental)
				} label: {
					Label("Run Loopback Health Check (Experimental)", systemImage: "flask")
				}
				.disabled(pairingCore.isGate2Running)

				if pairingCore.gate2Endpoint != .localDevVPN {
					LabeledContent("Target") {
						Text("\(pairingCore.gate2Endpoint.address):\(ZagDeviceLink.rsdPort)")
							.font(.footnote.monospaced())
					}
				}
				if let last = pairingCore.gate2Steps.last, !pairingCore.isGate2Running {
					LabeledContent("Duration") { Text("\(last.elapsedMilliseconds) ms") }
				}

				Button {
					reportState = .preparing
					Task { @MainActor in
						let report = await ZagLocalVPNMonitor.shared.makeReport(
							steps: pairingCore.gate2Steps,
							sessionFailure: pairingCore.gate2Failure,
							endpoint: pairingCore.gate2Endpoint
						)
						UIPasteboard.general.string = report
						reportState = .copied
					}
				} label: {
					switch reportState {
					case .idle: Label("Copy Diagnostic Report", systemImage: "doc.on.doc")
					case .preparing: Label("Preparing Report…", systemImage: "hourglass")
					case .copied: Label("Report Copied", systemImage: "checkmark")
					}
				}
				.disabled(pairingCore.isGate2Running || reportState == .preparing)
			} header: {
				Text("Health Checks")
			} footer: {
				Text("Connect LocalDevVPN first. This verifies pairing, Pair-Verify, TLS-PSK, RSD, Installation Proxy, app lookup, and AFC/PublicStaging write-read-cleanup. The copied report includes the network type, timings and the first failing step, without device names, identifiers or keys.")
			}

			Section {
				Button {
					traceState = .preparing
					Task { @MainActor in
						guard !pairingCore.isTransportBusy else {
							traceSummary = ["A device session is running. Try again when it finishes."]
							traceState = .idle
							return
						}
						let result = await ZagTransportTrace.run()
						traceSummary = ZagTransportTrace.findings(result)
						UIPasteboard.general.string = ZagTransportTrace.report(
							result,
							deviceSummary: "\(UIDevice.current.model), iOS \(UIDevice.current.systemVersion)"
						)
						traceState = .copied
					}
				} label: {
					switch traceState {
					case .idle: Label("Run Connection Trace", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
					case .preparing: Label("Tracing…", systemImage: "hourglass")
					case .copied: Label("Trace Copied", systemImage: "checkmark")
					}
				}
				.disabled(traceState == .preparing || pairingCore.isGate2Running)

				ForEach(traceSummary, id: \.self) { finding in
					Text(finding).font(.footnote).textSelection(.enabled)
				}
			} header: {
				Text("Connection Trace")
			} footer: {
				Text("Tests whether TCP crosses LocalDevVPN and how the RemotePairing port answers on this network, then copies a redacted trace. Nothing is sent on these connections. Run it on Wi-Fi and on mobile data and compare.")
			}

			Section {
				ForEach(ZagMobileDataToggle.Command.allCases, id: \.self) { command in
					Button {
						toggleLogCopied = false
						mobileDataToggle.run(command)
					} label: {
						Label("Run \(command.rawValue)", systemImage: command == .status ? "checkmark.shield" : (command == .off ? "antenna.radiowaves.left.and.right.slash" : "antenna.radiowaves.left.and.right"))
					}
					.disabled(mobileDataToggle.isBusy || pairingCore.isGate2Running)
				}

				if mobileDataToggle.isBusy {
					Button("Cancel", role: .cancel) { mobileDataToggle.cancel() }
				}

				ForEach(mobileDataToggle.events) { event in
					Text("+\(event.milliseconds) ms  \(event.text)")
						.font(.footnote.monospaced())
						.textSelection(.enabled)
				}

				if !mobileDataInstall.decisionLog.isEmpty {
					DisclosureGroup("Last Install or Removal Decision") {
						ForEach(Array(mobileDataInstall.decisionLog.enumerated()), id: \.offset) { _, line in
							Text(line)
								.font(.footnote.monospaced())
								.textSelection(.enabled)
						}
					}
				}

				if !mobileDataToggle.events.isEmpty || !mobileDataInstall.decisionLog.isEmpty {
					Button {
						UIPasteboard.general.string = mobileDataToggle.report()
							+ "\n\nLast install or removal decision\n"
							+ mobileDataInstall.decisionLog.joined(separator: "\n")
						toggleLogCopied = true
					} label: {
						Label(toggleLogCopied ? "Log Copied" : "Copy Shortcut Log", systemImage: toggleLogCopied ? "checkmark" : "doc.on.doc")
					}
				}
			} header: {
				Text(ZagMobileDataToggle.shortcutName)
			} footer: {
				Text("Runs the Shortcut with one command and records every callback parameter Shortcuts returns. After off, RPPairing readiness is confirmed by the full health check; after on, by the system network path.")
			}

			Section {
				Button {
					refreshInstalledAppsInventory()
				} label: {
					Label(
						pairingCore.installedAppsState == .refreshing ? "Refreshing Installed Apps…" : "View Installed App Versions",
						systemImage: "list.bullet.rectangle"
					)
				}
				.disabled(!pairingCore.pairingFileExists || pairingCore.installedAppsState == .refreshing)

				if case .loaded(let count) = pairingCore.installedAppsState {
					LabeledContent("Last Inventory") { Text("\(count) apps") }
				}

				if let debugKeys = pairingCore.installedAppsDebugKeys, !debugKeys.isEmpty {
					VStack(alignment: .leading, spacing: 4) {
						Text("Returned Metadata Keys")
							.font(.caption.weight(.semibold))
							.foregroundStyle(.secondary)
						Text(debugKeys)
							.font(.caption.monospaced())
							.textSelection(.enabled)
					}
				}
			} header: {
				Text("Installed App Inventory")
			} footer: {
				Text("Reads the actual user-app inventory from installation_proxy and shows the bundle identifier, installed version and build reported by this iPhone.")
			}

			Section {
				Button {
					do {
						try pairingCore.listSharedDocuments(bundleID: "com.SideStore.SideStore")
					} catch {
						healthMessage = error.localizedDescription
					}
				} label: {
					Label(
						pairingCore.houseArrestRunning ? "Testing SideStore Documents…" : "Test SideStore Documents",
						systemImage: "folder.badge.gearshape"
					)
				}
				.disabled(!pairingCore.pairingFileExists || pairingCore.houseArrestRunning)

				Button {
					do {
						try pairingCore.installPairingFileInSideStore()
					} catch {
						healthMessage = error.localizedDescription
					}
				} label: {
					Label(
						pairingCore.houseArrestPairingInstallRunning ? "Installing Pairing File…" : "Install Pairing File in SideStore",
						systemImage: "doc.badge.arrow.up"
					)
				}
				.disabled(
					!pairingCore.pairingFileExists ||
					pairingCore.houseArrestPairingInstallRunning ||
					pairingCore.houseArrestRunning
				)

				if let status = pairingCore.houseArrestPairingInstallStatus {
					Text(status)
						.font(.footnote)
						.foregroundStyle(status == "SideStore pairing file installed" ? .green : .secondary)
						.textSelection(.enabled)
				}

				if let error = pairingCore.houseArrestPairingInstallError {
					Text(error)
						.font(.footnote)
						.foregroundStyle(.red)
						.textSelection(.enabled)
				}

				if let bundleID = pairingCore.houseArrestBundleID {
					LabeledContent("Resolved Bundle ID") {
						Text(bundleID).font(.caption).textSelection(.enabled)
					}
				}

				if let error = pairingCore.houseArrestError {
					Text(error).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
				} else if !pairingCore.houseArrestDocuments.isEmpty {
					ForEach(pairingCore.houseArrestDocuments, id: \.self) { entry in
						Label(entry, systemImage: "doc")
							.font(.caption)
							.textSelection(.enabled)
					}
				} else if pairingCore.houseArrestBundleID != nil && !pairingCore.houseArrestRunning {
					Text("Documents is accessible and currently empty.")
						.font(.footnote)
						.foregroundStyle(.secondary)
				}
			} header: {
				Text("House Arrest Test")
			} footer: {
				Text("Read-only diagnostic. Vends SideStore's shared Documents domain through House Arrest and lists its contents without modifying files.")
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
					showGate4SignedPicker = true
				} label: {
					Label("Run Installation Test…", systemImage: "shippingbox")
				}
				.disabled(
					pairingCore.isGate4Running ||
					!pairingCore.pairingFileExists ||
					signedApps.isEmpty
				)
			} header: {
				Text("Installation Test")
			} footer: {
				Text("Select an app already signed by Zag Store. Diagnostics creates a temporary IPA and runs it through the complete RPPairing direct-install path.")
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
		.sheet(isPresented: $showInstalledAppsInventory) {
			NavigationStack {
				List {
					ForEach(pairingCore.installedApps.values.sorted { $0.bundleID.localizedCaseInsensitiveCompare($1.bundleID) == .orderedAscending }, id: \.bundleID) { app in
						VStack(alignment: .leading, spacing: 4) {
							Text(app.bundleID)
								.font(.body.weight(.medium))
								.textSelection(.enabled)
							HStack(spacing: 8) {
								Text("Version: \(app.version.isEmpty ? "—" : app.version)")
								Text("Build: \(app.build.isEmpty ? "—" : app.build)")
							}
							.font(.caption)
							.foregroundStyle(.secondary)
						}
						.padding(.vertical, 2)
					}
				}
				.navigationTitle("Installed Apps")
				.navigationBarTitleDisplayMode(.inline)
				.toolbar {
					ToolbarItem(placement: .confirmationAction) {
						Button("Done") { showInstalledAppsInventory = false }
					}
				}
			}
		}
		.alert("Installed Apps Lookup", isPresented: Binding(
			get: { inventoryError != nil },
			set: { if !$0 { inventoryError = nil } }
		)) {
			Button("OK", role: .cancel) { inventoryError = nil }
		} message: {
			Text(inventoryError ?? "")
		}
		.sheet(isPresented: $showGate4SignedPicker) {
			NavigationStack {
				List {
					ForEach(signedApps, id: \.objectID) { app in
						Button {
							showGate4SignedPicker = false
							runGate4InstallationTest(with: app)
						} label: {
							VStack(alignment: .leading, spacing: 4) {
								Text(app.name ?? "Unknown App")
									.foregroundStyle(.primary)

								HStack(spacing: 6) {
									if let version = app.version, !version.isEmpty {
										Text(version)
									}

									if let identifier = app.identifier, !identifier.isEmpty {
										Text(identifier)
									}
								}
								.font(.caption)
								.foregroundStyle(.secondary)
							}
						}
						.disabled(app.identifier == "com.cwd43.gu29")
					}
				}
				.navigationTitle("Choose Signed App")
				.navigationBarTitleDisplayMode(.inline)
				.toolbar {
					ToolbarItem(placement: .cancellationAction) {
						Button("Cancel") {
							showGate4SignedPicker = false
						}
					}
				}
			}
		}
	}

	private func refreshInstalledAppsInventory() {
		do {
			try pairingCore.refreshInstalledApps { result in
				DispatchQueue.main.async {
					switch result {
					case .success:
						showInstalledAppsInventory = true
					case .failure(let error):
						inventoryError = error.localizedDescription
					}
				}
			}
		} catch {
			inventoryError = error.localizedDescription
		}
	}

	private func runGate4InstallationTest(with app: Signed) {
		Task {
			do {
				let archive = ArchiveHandler(app: app)

				try await archive.move()
				let packageURL = try await archive.archive()

				try pairingCore.installGate4IPA(at: packageURL)
			} catch {
				await MainActor.run {
					healthMessage = "Installation test preparation failed: \(error.localizedDescription)"
				}
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
		case .uploading(let percent): return "Uploading signed IPA — \(percent)%"
		case .staged: return "Signed IPA staged and verified"
		case .upgradeSubmitted: return "Upgrade submitted to iOS"
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

