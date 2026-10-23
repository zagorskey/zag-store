//
//  LibraryInfoView.swift
//  Feather
//
//  Created by samara on 14.04.2025.
//

import SwiftUI
import NimbleViews
import Zsign
import AltSourceKit
import NukeUI

// MARK: - View
struct LibraryInfoView: View {
	var app: AppInfoPresentable
	@ObservedObject private var sourcesViewModel = SourcesViewModel.shared
	@State private var selectedRepositorySource: AltSource?
	@State private var promotionalHeaderImage: UIImage?

	// Use a repository entry only when the installed/imported app can be
	// linked to its actual source. Otherwise use Apple's exact identity or
	// unambiguous title match; never borrow artwork from an unrelated app.
	private var artworkRepositoryApp: ASRepository.App? {
		guard let identifier = app.identifier,
			  let origin = _repositoryOrigin else { return nil }
		return origin.1.apps.first {
			$0.id?.caseInsensitiveCompare(identifier) == .orderedSame
		}
	}

	private var artworkRequestKey: String {
		[
			app.identifier ?? "",
			app.name ?? "",
			artworkRepositoryApp?.currentUniqueId ?? "",
			artworkRepositoryApp?.currentPromotionalArtworkURL?.absoluteString ?? ""
		].joined(separator: "|")
	}
	
	// MARK: Body
	var body: some View {
		NBNavigationView(app.name ?? "", displayMode: .inline) {
			List {
				Section {} header: {
					VStack(spacing: 14) {
						if let image = promotionalHeaderImage {
							ZagAppDetailHeaderImage(hero: .landscape(image))
								.frame(height: 190)
								.clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
								.padding(.horizontal, 6)
								.accessibilityLabel("Verified app screenshot")
						}
						FRAppIconView(app: app)
							.frame(maxWidth: .infinity, alignment: .center)
					}
					.frame(maxWidth: .infinity)
				}
				
				_infoSection(for: app)
				_repositorySection
				_certSection(for: app)
				_bundleSection(for: app)
				_executableSection(for: app)
				
				Section {
					Button(.localized("Open in Files"), systemImage: "folder") {
						UIApplication.open(Storage.shared.getUuidDirectory(for: app)!.toSharedDocumentsURL()!)
					}
				}
			}
			.navigationDestination(
				isPresented: Binding(
					get: { selectedRepositorySource != nil },
					set: { if !$0 { selectedRepositorySource = nil } }
				)
			) {
				if let source = selectedRepositorySource {
					SourceAppsView(
						object: [source],
						viewModel: sourcesViewModel
					)
				}
			}
			.toolbar {
				NBToolbarButton(role: .close)
			}
			.task(id: artworkRequestKey) {
				promotionalHeaderImage = nil
				guard let url = artworkRepositoryApp?.currentPromotionalArtworkURL,
					let image = await ZagFeaturedImageCache.shared.load(url),
					image.width >= 850, image.height >= 420,
					Double(image.width) / Double(image.height) >= 1.25 else { return }
				guard !Task.isCancelled else { return }
				promotionalHeaderImage = UIImage(data: image.data)
			}
		}
	}
}

// MARK: - Extension: View
extension LibraryInfoView {
	@ViewBuilder
	private func _infoSection(for app: AppInfoPresentable) -> some View {
		NBSection(.localized("Info")) {
			if let name = app.name {
				_infoCell(.localized("Name"), desc: name)
			}
			
			if let ver = app.version {
				_infoCell(.localized("Version"), desc: ver)
			}
			
			if let id = app.identifier {
				_infoCell(.localized("Identifier"), desc: id)
			}
			
			if let date = app.date {
				_infoCell(.localized("Date Added"), desc: date.formatted())
			}
		}
	}
	
	private var _repositoryOrigin: (AltSource, ASRepository)? {
		guard let bundleID = app.identifier, !bundleID.isEmpty else { return nil }

		let origins = UserDefaults.standard.dictionary(
			forKey: "zagStore.repositoryOrigins"
		) as? [String: String]
		let origin = origins?[bundleID]

		if let origin,
		   let match = sourcesViewModel.sources.first(where: { storedSource, repository in
			   storedSource.sourceURL?.absoluteString == origin ||
			   repository.id == origin ||
			   repository.website?.absoluteString == origin ||
			   repository.name == origin
		   }) {
			return match
		}

		let matches = sourcesViewModel.sources.filter { _, repository in
			repository.apps.contains { $0.id == bundleID }
		}
		return origin == nil && matches.count == 1 ? matches.first : nil
	}

	@ViewBuilder
	private var _repositorySection: some View {
		if let origin = _repositoryOrigin {
			NBSection(.localized("Source")) {
				Button {
					selectedRepositorySource = origin.0
				} label: {
					HStack(spacing: 12) {
						if let iconURL = origin.1.currentIconURL {
							LazyImage(url: iconURL) { state in
								if let image = state.image {
									image.appIconStyle(
										size: 34,
										isCircle: true,
										background: Color(uiColor: .secondarySystemBackground)
									)
								}
							}
							.frame(width: 34, height: 34)
						}

						Text(origin.1.name ?? .localized("Repository"))
							.foregroundStyle(.primary)
						Spacer()
						Image(systemName: "chevron.right")
							.font(.footnote.weight(.semibold))
							.foregroundStyle(.tertiary)
					}
				}
				.buttonStyle(.plain)
			}
		}
	}

	@ViewBuilder
	private func _certSection(for app: AppInfoPresentable) -> some View {
		if let cert = Storage.shared.getCertificate(from: app) {
			NBSection(.localized("Certificate")) {
				CertificatesCellView(
					cert: cert
				)
			}
		}
	}
	
	@ViewBuilder
	private func _bundleSection(for app: AppInfoPresentable) -> some View {
		NBSection(.localized("Bundle")) {
			NavigationLink(.localized("Alternative Icons")) {
				SigningAlternativeIconView(app: app, appIcon: .constant(nil), isModifing: .constant(false))
			}
			NavigationLink(.localized("Frameworks & PlugIns")) {
				SigningFrameworksView(app: app, options: .constant(nil))
			}
		}
	}
	
	@ViewBuilder
	private func _executableSection(for app: AppInfoPresentable) -> some View {
		NBSection(.localized("Executable")) {
			NavigationLink(.localized("Dylibs")) {
				SigningDylibView(app: app, options: .constant(nil))
			}
		}
	}
	
	@ViewBuilder
	private func _infoCell(_ title: String, desc: String) -> some View {
		LabeledContent(title) {
			Text(desc)
		}
		.copyableText(desc)
	}
}
