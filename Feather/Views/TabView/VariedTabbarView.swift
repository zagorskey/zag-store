//
//  VariedTabbarView.swift
//  Zag Store
//
//  Created by samara on 11.04.2025.
//

import SwiftUI
import CoreData
import UIKit

extension Notification.Name {
	static let zagProfileAvatarDidChange = Notification.Name("ZagStore.profileAvatarDidChange")
}

enum ZagProfileAvatarStore {
	private static let fileName = "zag-profile-avatar.jpg"
	static var customURL: URL {
		FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent(fileName)
	}
	static func customImage() -> UIImage? { UIImage(contentsOfFile: customURL.path) }
	static func save(_ data: Data) throws {
		let directory = customURL.deletingLastPathComponent()
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		guard let image = UIImage(data: data),
		      let encoded = image.jpegData(compressionQuality: 0.9) else {
			throw CocoaError(.fileReadCorruptFile)
		}
		try encoded.write(to: customURL, options: .atomic)
		NotificationCenter.default.post(name: .zagProfileAvatarDidChange, object: nil)
	}
	static func removeCustomImage() {
		try? FileManager.default.removeItem(at: customURL)
		NotificationCenter.default.post(name: .zagProfileAvatarDidChange, object: nil)
	}
}

struct VariedTabbarView: View {
	@AppStorage(ZagWallpaperStore.enabledKey) private var wallpaperEnabled = false
	@StateObject private var sourcesViewModel = SourcesViewModel.shared
	@StateObject private var updateManager = UpdateManager.shared

	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [
			NSSortDescriptor(
				keyPath: \AltSource.name,
				ascending: true
			)
		],
		animation: .snappy
	)
	private var sources: FetchedResults<AltSource>

	init() {}

	var body: some View {
		Group {
			if #available(iOS 18, *) {
				ExtendedTabbarView()
			} else {
				TabbarView()
			}
		}
		.background {
			if wallpaperEnabled {
				Color.clear
			}
		}
		.task {
			await updateManager.requestBadgePermission()
			await sourcesViewModel.fetchSources(sources, refresh: true)
		}
		.onReceive(sourcesViewModel.$sources) { _ in
			// SourcesViewModel commits repository and update state together.
		}
	}
}

struct ZagProfileToolbarButton: View {
	@StateObject private var updateManager = UpdateManager.shared
	@State private var isAccountPresenting = false
	@State private var avatarRevision = UUID()
	@GestureState private var isPressing = false

	var body: some View {
		Button {
			isAccountPresenting = true
		} label: {
			ZagGlobalProfileAvatar(revision: avatarRevision)
				.frame(width: 40, height: 40)
				.scaleEffect(isPressing ? 1.09 : 1)
				.brightness(isPressing ? 0.10 : 0)
				.shadow(
					color: .white.opacity(isPressing ? 0.24 : 0),
					radius: isPressing ? 7 : 0
				)
				.animation(
					.interpolatingSpring(stiffness: 420, damping: 22),
					value: isPressing
				)
		}
		.buttonStyle(.plain)
		.overlay(alignment: .topTrailing) {
			if updateManager.updateCount > 0 {
				Text(updateManager.updateCount.description)
					.font(.system(size: 13, weight: .regular))
					.foregroundStyle(.white)
					.padding(.horizontal, 6)
					.frame(minWidth: 24, minHeight: 24)
					.background(
						Color(red: 1.0, green: 0.145, blue: 0.20),
						in: Capsule()
					)
					.offset(x: 7, y: -6)
					.opacity(isAccountPresenting ? 0 : 1)
					.scaleEffect(isAccountPresenting ? 0.72 : 1)
					.animation(
						.interpolatingSpring(stiffness: 300, damping: 27),
						value: isAccountPresenting
					)
					.allowsHitTesting(false)
			}
		}
		.simultaneousGesture(
			DragGesture(minimumDistance: 0)
				.updating($isPressing) { _, state, _ in
					state = true
				}
		)
		.accessibilityLabel("Account and App Updates")
		.onReceive(NotificationCenter.default.publisher(for: .zagProfileAvatarDidChange)) { _ in
			avatarRevision = UUID()
		}
		.sheet(isPresented: $isAccountPresenting) {
			ZagAccountPopup()
		}
	}
}

struct ZagGlobalProfileAvatar: View {
	let revision: UUID
	@Environment(\.colorScheme) private var colorScheme
	var body: some View {
		Group {
			if let image = ZagProfileAvatarStore.customImage() {
				Image(uiImage: image).resizable().scaledToFill()
			} else {
				Image(colorScheme == .dark ? "ZagProfileDark" : "ZagProfileLight")
					.resizable().scaledToFill()
			}
		}
		.id(revision)
		.clipShape(Circle())
		.background(.ultraThinMaterial, in: Circle())
		.overlay(Circle().stroke(.white.opacity(0.16), lineWidth: 0.5))
		.shadow(color: .black.opacity(0.18), radius: 8, y: 3)
	}
}

struct ZagAccountPopup: View {
	@ObservedObject private var updateManager = UpdateManager.shared
	@Environment(\.dismiss) private var dismiss
	@State private var avatarRevision = UUID()

	var body: some View {
		NavigationStack {
			Form {
				Section {
					HStack(spacing: 14) {
						ZagGlobalProfileAvatar(revision: avatarRevision)
							.frame(width: 62, height: 62)
						VStack(alignment: .leading, spacing: 3) {
							Text("Zag Store").font(.title3.weight(.semibold))
							Text("Profile").foregroundStyle(.secondary)
						}
					}
					.padding(.vertical, 6)
				}
				Section {
					NavigationLink {
						ZagUpdatesPopup(updates: updateManager.updates)
					} label: {
						HStack {
							Label("App Updates", systemImage: "arrow.down.app")
							Spacer()
							if updateManager.updateCount > 0 {
								Text(updateManager.updateCount.description)
									.font(.caption.weight(.bold))
									.foregroundStyle(.white)
									.padding(.horizontal, 7)
									.frame(minHeight: 24)
									.background(Color.red, in: Capsule())
							}
						}
					}
				}
			}
			.navigationTitle("Account")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button { dismiss() } label: { Image(systemName: "xmark") }
						.accessibilityLabel("Close")
				}
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: .zagProfileAvatarDidChange)) { _ in
			avatarRevision = UUID()
		}
	}
}
