//
//  CertificateCellView.swift
//  Feather
//
//  Created by samara on 16.04.2025.
//

import SwiftUI
import NimbleViews
import UIKit

// MARK: - View
struct CertificatesCellView: View {
	@State var data: Certificate?
	@State private var isCopyFeedbackActive = false
	@State private var copyFeedbackResetTask: Task<Void, Never>?

	@ObservedObject var cert: CertificatePair

	// MARK: Body
	var body: some View {
		VStack(spacing: 6) {
			let title = {
				var title = cert.nickname ?? data?.Name ?? .localized("Unknown")

				if let getTaskAllow = data?.Entitlements?["get-task-allow"]?.value as? Bool,
				   getTaskAllow == true {
					title = "🐞 \(title)"
				}

				return title
			}()

			VStack(spacing: 2) {
				HStack(spacing: 5) {
					Text(title)
						.font(.system(size: 20, weight: .semibold))
						.lineLimit(1)
						.minimumScaleFactor(0.62)
						.layoutPriority(1)

					Button {
						_copyCertificateName()
					} label: {
						Image(systemName: "doc.on.doc")
							.font(.system(size: 13, weight: .semibold))
							.foregroundStyle(
								isCopyFeedbackActive
									? copyFeedbackColor
									: Color(hex: "#CCCCCC")
							)
							.frame(width: 28, height: 24)
							.contentShape(Rectangle())
							.animation(
								.easeInOut(duration: 0.18),
								value: isCopyFeedbackActive
							)
					}
					.buttonStyle(.plain)
					.accessibilityLabel("Copy Certificate Name")
					.accessibilityHint("Copies the original certificate name")
				}
				.frame(maxWidth: .infinity)

				Text(data?.AppIDName ?? .localized("Unknown"))
					.font(.system(size: 14, weight: .regular))
					.foregroundStyle(.secondary)
					.lineLimit(1)
					.frame(maxWidth: .infinity)
					.multilineTextAlignment(.center)
			}
			.frame(maxWidth: .infinity)

			_certInfoPill(data: cert)
		}
		.frame(maxWidth: .infinity)
		.frame(height: 80)
		.contentTransition(.opacity)
		.onAppear {
			guard let uuid = cert.uuid else { return }
			let directory = FileManager.default.certificates(uuid)
			guard let provisionURL = FileManager.default.getPath(
				in: directory,
				for: Storage.FileRequest.provision.rawValue
			) else {
				return
			}

			Task.detached(priority: .userInitiated) {
				let decoded = CertificateReader(provisionURL).decoded
				await MainActor.run {
					data = decoded
				}
			}
		}
	}
}

// MARK: - Extension: View
extension CertificatesCellView {
	private var copyFeedbackColor: Color {
		cert.expiration?.expirationInfo().color ?? .green
	}

	private func _copyCertificateName() {
		// Always copy the certificate's original embedded name. A user-facing
		// nickname is display-only and must never replace the copied value.
		let certificateName = data?.Name ?? .localized("Unknown")
		UIPasteboard.general.string = certificateName

		UIImpactFeedbackGenerator(style: .light).impactOccurred()
		UIAccessibility.post(
			notification: .announcement,
			argument: "Certificate name copied"
		)

		copyFeedbackResetTask?.cancel()
		withAnimation(.easeInOut(duration: 0.18)) {
			isCopyFeedbackActive = true
		}

		copyFeedbackResetTask = Task { @MainActor in
			try? await Task.sleep(nanoseconds: 650_000_000)
			guard !Task.isCancelled else { return }
			withAnimation(.easeInOut(duration: 0.28)) {
				isCopyFeedbackActive = false
			}
		}
	}

	@ViewBuilder
	private func _certInfoPill(data: CertificatePair) -> some View {
		let pillItems = _buildPills(from: data)

		HStack(spacing: 6) {
			ForEach(pillItems.indices, id: \.hashValue) { index in
				let pill = pillItems[index]

				NBPillView(
					title: pill.title,
					icon: pill.icon,
					color: pill.color,
					index: index,
					count: pillItems.count,
					compact: true
				)
			}
		}
		.frame(maxWidth: .infinity)
	}

	private func _buildPills(from cert: CertificatePair) -> [NBPillItem] {
		var pills: [NBPillItem] = []

		if cert.ppQCheck == true {
			pills.append(
				NBPillItem(
					title: .localized("PPQCheck"),
					icon: "checkmark.shield",
					color: .red
				)
			)
		}

		if cert.revoked == true {
			pills.append(
				NBPillItem(
					title: .localized("Revoked"),
					icon: "xmark.octagon",
					color: .red
				)
			)
		}

		if let info = cert.expiration?.expirationInfo() {
			pills.append(
				NBPillItem(
					title: info.formatted,
					icon: info.icon,
					color: info.color
				)
			)
		}

		return pills
	}
}
