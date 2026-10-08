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

enum ZagWideGamutTint {
	static func color(hex: String) -> Color {
		// Treat the theme's RGB hex values as native Display P3 components.
		// Converting through UIColor(Color(hex:)) would first interpret them as sRGB.
		// Native uses the vivid system-blue P3 components rather than the softer
		// palette swatch (#3F8EF7). V2 and Berry retain their selected hex.
		if hex.uppercased() == "#3F8EF7" {
			return Color(uiColor: UIColor(displayP3Red: 0, green: 0.47843137, blue: 1, alpha: 1))
		}
		let digits = hex.trimmingCharacters(in: .whitespacesAndNewlines)
			.replacingOccurrences(of: "#", with: "")
		guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
			return Color(hex: hex)
		}
		let red = CGFloat((value >> 16) & 0xFF) / 255
		let green = CGFloat((value >> 8) & 0xFF) / 255
		let blue = CGFloat(value & 0xFF) / 255
		return Color(uiColor: UIColor(displayP3Red: red, green: green, blue: blue, alpha: 1))
	}
}

struct VariedTabbarView: View {
	@AppStorage("Feather.userTintColor") private var themeColorHex: String = "#3F8EF7"
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
		.onAppear { updateDockTint() }
		.onChange(of: themeColorHex) { _ in updateDockTint() }
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
	private func updateDockTint() {
		let color = UIColor(ZagWideGamutTint.color(hex: themeColorHex))
		// SwiftUI's native tab bar may override tintColor. Set the selected
		// image AND title appearance explicitly, without tinting page content.
		let appearance = UITabBarAppearance()
		appearance.configureWithDefaultBackground()
		for items in [appearance.stackedLayoutAppearance,
		              appearance.inlineLayoutAppearance,
		              appearance.compactInlineLayoutAppearance] {
			items.selected.iconColor = color
			items.selected.titleTextAttributes = [.foregroundColor: color]
		}
		UITabBar.appearance().tintColor = color
		UITabBar.appearance().standardAppearance = appearance
		if #available(iOS 15.0, *) {
			UITabBar.appearance().scrollEdgeAppearance = appearance
		}
		for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
			for window in scene.windows {
				updateTabBars(in: window.rootViewController, color: color, appearance: appearance)
			}
		}
	}

	private func updateTabBars(in controller: UIViewController?, color: UIColor, appearance: UITabBarAppearance) {
		guard let controller else { return }
		if let tabs = controller as? UITabBarController {
			tabs.tabBar.tintColor = color
			tabs.tabBar.standardAppearance = appearance
			if #available(iOS 15.0, *) {
				tabs.tabBar.scrollEdgeAppearance = appearance
			}
		}
		for child in controller.children {
			updateTabBars(in: child, color: color, appearance: appearance)
		}
		if let presented = controller.presentedViewController {
			updateTabBars(in: presented, color: color, appearance: appearance)
		}
	}

}

private struct ZagProfilePressStyle: ButtonStyle {
	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.scaleEffect(configuration.isPressed ? 1.075 : 1)
			.brightness(configuration.isPressed ? 0.12 : 0)
			.shadow(color: .white.opacity(configuration.isPressed ? 0.32 : 0),
			        radius: configuration.isPressed ? 6 : 0)
			.animation(.spring(response: 0.32, dampingFraction: 0.53),
			           value: configuration.isPressed)
	}
}

private struct ZagBadgeAnchor: UIViewRepresentable {
	let count: Int
	let hidden: Bool
	func makeUIView(context: Context) -> ZagBadgeAnchorView { ZagBadgeAnchorView() }
	func updateUIView(_ view: ZagBadgeAnchorView, context: Context) {
		view.update(count: count, hidden: hidden)
	}
}

private final class ZagBadgeAnchorView: UIView {
	private let badge = UILabel()
	private var count = 0
	private var badgeHidden = false
	private weak var hostWindow: UIWindow?
	override init(frame: CGRect) {
		super.init(frame: frame)
		isUserInteractionEnabled = false
		backgroundColor = .clear
		badge.textAlignment = .center
		badge.textColor = .white
		badge.font = .systemFont(ofSize: 12, weight: .regular)
		badge.backgroundColor = UIColor(displayP3Red: 1, green: 0.12, blue: 0.16, alpha: 1)
		badge.layer.cornerRadius = 10
		badge.layer.masksToBounds = true
		badge.isUserInteractionEnabled = false
	}
	required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
	func update(count: Int, hidden: Bool) {
		self.count = count
		badgeHidden = hidden
		badge.text = String(count)
		badge.isHidden = count == 0 || hidden
		UIView.animate(withDuration: 0.24) {
			self.badge.alpha = hidden ? 0 : 1
		}
		setNeedsLayout()
		positionBadge()
	}
	override func didMoveToWindow() {
		super.didMoveToWindow()
		if hostWindow !== window {
			badge.removeFromSuperview()
			hostWindow = window
			window?.addSubview(badge)
		}
		positionBadge()
	}
	override func layoutSubviews() {
		super.layoutSubviews()
		positionBadge()
	}
	private func positionBadge() {
		guard let window, bounds.width > 0 else { return }
		let rect = convert(bounds, to: window)
		let width = max(20, CGFloat(String(count).count) * 8 + 10)
		badge.frame = CGRect(x: rect.maxX - width + 4,
		                     y: rect.minY - 9, width: width, height: 20)
		window.bringSubviewToFront(badge)
	}
	deinit { badge.removeFromSuperview() }
}

struct ZagProfileToolbarButton: View {
	@StateObject private var updateManager = UpdateManager.shared
	@State private var isAccountPresenting = false
	@State private var avatarRevision = UUID()
	var body: some View {
		Button {
			withAnimation(.easeInOut(duration: 0.24)) { isAccountPresenting = true }
		} label: {
			ZagGlobalProfileAvatar(revision: avatarRevision)
				.frame(width: 40, height: 40)
				.contentShape(Circle())
				.background {
					ZagBadgeAnchor(count: updateManager.updateCount,
					               hidden: isAccountPresenting)
				}
		}
		.buttonStyle(ZagProfilePressStyle())
		.tint(.primary)
		.contentShape(Circle())
		.accessibilityLabel("Account and App Updates")
		.onReceive(NotificationCenter.default.publisher(for: .zagProfileAvatarDidChange)) { _ in
			avatarRevision = UUID()
		}
		.sheet(isPresented: $isAccountPresenting) { ZagAccountPopup() }
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
