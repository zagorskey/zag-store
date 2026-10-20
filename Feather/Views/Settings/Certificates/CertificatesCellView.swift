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
        let title = cert.nickname ?? data?.Name ?? "Unknown Certificate"
        let profileExpiry = data?.ExpirationDate ?? cert.expiration
        let isCurrent = data.map { $0.CreationDate <= Date() && $0.ExpirationDate > Date() } ?? false
        let hasP12 = Storage.shared.getFile(.certificate, from: cert) != nil
        let needsAttention = cert.revoked || !isCurrent || !hasP12

        return VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: needsAttention ? "exclamationmark.shield" : "checkmark.shield")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(needsAttention ? Color.orange : Color.accentColor)
                    .frame(width: 46, height: 46)
                    .background(
                        (needsAttention ? Color.orange : Color.accentColor).opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text(data?.TeamName ?? data?.AppIDName ?? "Unknown signing team")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button {
                    _copyCertificateName()
                } label: {
                    Image(systemName: isCopyFeedbackActive ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isCopyFeedbackActive ? copyFeedbackColor : Color.secondary)
                        .frame(width: 34, height: 34)
                        .background(Color.primary.opacity(0.05), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy Certificate Name")
                .accessibilityHint("Copies the original provisioning profile name")
            }

            HStack(spacing: 8) {
                Label(
                    cert.revoked ? "Marked revoked" :
                    !hasP12 ? "P12 missing" :
                    !isCurrent ? "Profile not current" : "Files present",
                    systemImage: needsAttention ? "exclamationmark.circle" : "checkmark.circle"
                )
                .foregroundStyle(needsAttention ? Color.orange : Color.secondary)

                Spacer(minLength: 4)

                if let profileExpiry {
                    Label {
                        Text(profileExpiry, style: .date)
                    } icon: {
                        Image(systemName: "calendar")
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.75)

            if cert.ppQCheck {
                Label("PPQ Check", systemImage: "shield.lefthalf.filled")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            guard let uuid = cert.uuid else { return }
            let directory = FileManager.default.certificates(uuid)
            guard let provisionURL = FileManager.default.getPath(
                in: directory,
                for: Storage.FileRequest.provision.rawValue
            ) else { return }

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
