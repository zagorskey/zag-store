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
        let profile = data ?? Storage.shared.getProvisionFileDecoded(for: cert)
        let title = cert.nickname ?? profile?.Name ?? "Unknown Certificate"
        let profileExpiry = profile?.ExpirationDate ?? cert.expiration
        let isCurrent = profile.map { $0.CreationDate <= Date() && $0.ExpirationDate > Date() } ?? false
        let hasP12 = Storage.shared.getFile(.certificate, from: cert) != nil
        let now = Date()
        let expiringSoon = profile.map {
            $0.ExpirationDate > now && $0.ExpirationDate <= now.addingTimeInterval(30 * 24 * 60 * 60)
        } ?? false
        let needsAttention = cert.revoked || !isCurrent || !hasP12 || expiringSoon

        return VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: needsAttention ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(
                        needsAttention
                            ? Color(uiColor: UIColor(displayP3Red: 0.96, green: 0.23, blue: 0.27, alpha: 1))
                            : Color(uiColor: UIColor(displayP3Red: 0.12, green: 0.83, blue: 0.34, alpha: 1))
                    )
                    .frame(width: 46, height: 46)
                    .background(
                        needsAttention
                            ? Color(uiColor: UIColor(displayP3Red: 0.30, green: 0.10, blue: 0.13, alpha: 1))
                            : Color(uiColor: UIColor(displayP3Red: 0.08, green: 0.26, blue: 0.14, alpha: 1)),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text(profile?.TeamName ?? profile?.AppIDName ?? "Unknown signing team")
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
                if needsAttention {
                    Label(
                        cert.revoked ? "Marked revoked" :
                        !hasP12 ? "P12 missing" :
                        profile == nil ? "Profile unavailable" :
                        !isCurrent ? "Profile not current" : "Expiring soon",
                        systemImage: "exclamationmark.circle"
                    )
                    .foregroundStyle(Color.orange)
                }

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
