//
//  CertificateCellView.swift
//  Feather
//
//  Created by samara on 16.04.2025.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct CertificatesCellView: View {
	@State var data: Certificate?

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
				Text(title)
					.font(.system(size: 19, weight: .semibold))
					.lineLimit(1)
					.minimumScaleFactor(0.75)
					.frame(maxWidth: .infinity)
					.multilineTextAlignment(.center)

				Text(data?.AppIDName ?? .localized("Unknown"))
					.font(.subheadline)
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
			withAnimation {
				data = Storage.shared.getProvisionFileDecoded(for: cert)
			}
		}
	}
}

// MARK: - Extension: View
extension CertificatesCellView {
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
					count: pillItems.count
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
