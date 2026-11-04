//
//  VariedTabbarView.swift
//  Zag Store
//
//  Created by samara on 11.04.2025.
//

import SwiftUI
import CoreData
import PhotosUI
import Network
import UIKit

extension Notification.Name {
	static let zagProfileAvatarDidChange = Notification.Name("ZagStore.profileAvatarDidChange")
    static let zagUpdatesSheetVisibilityDidChange = Notification.Name("ZagStore.updatesSheetVisibilityDidChange")
    static let zagLaunchSplashVisibilityDidChange = Notification.Name("ZagStore.launchSplashVisibilityDidChange")
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
		// The default App Store-matched blue uses the same #0090FF
		// components in Display P3. Custom themes retain their selected hex.
		if hex.uppercased() == "#0090FF" {
			return Color(uiColor: UIColor(displayP3Red: 0, green: 144.0 / 255.0, blue: 1, alpha: 1))
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
	@AppStorage("Feather.userTintColor") private var themeColorHex: String = "#0090FF"
	@AppStorage(ZagWallpaperStore.enabledKey) private var wallpaperEnabled = false
	// The root view only calls these models from handlers; its body never
	// reads them. Observing them re-evaluated the whole tab hierarchy for
	// every repository that finished during a refresh.
	private let sourcesViewModel = SourcesViewModel.shared
	private let updateManager = UpdateManager.shared
	@StateObject private var pairingCore = ZagRPPairingCore.shared
	@State private var didStartInitialUpdateRefresh = false

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
		.onAppear {
            // Migrate only the previous built-in blues; leave custom themes intact.
            let previous = themeColorHex.uppercased()
            if ["#3F8EF7", "#4395F8"].contains(previous) {
                themeColorHex = "#0090FF"
            }
            updateDockTint()
        }
		.onChange(of: themeColorHex) { _ in updateDockTint() }
		.background {
			if wallpaperEnabled {
				Color.clear
			}
		}
		.onAppear {
			// The initial update refresh belongs to the application, not a
			// selected tab's SwiftUI .task lifetime. Tab navigation can cancel
			// .task and leave updates unavailable until Apps is opened.
			guard !didStartInitialUpdateRefresh else { return }
			didStartInitialUpdateRefresh = true
			Task { @MainActor in
				await ZagLaunchGate.shared.waitUntilSplashFinishes()
				// Notification permission is optional. It must never delay
				// catalogue loading or the App Updates popup.
				let refreshStarted = ZagPerformanceMonitor.now()
				await sourcesViewModel.fetchSources(sources, refresh: true)
				ZagPerformanceMonitor.shared.record(.sourcesRefresh, since: refreshStarted)
				ZagPerformanceMonitor.shared.markSourcesCompleted()
				await updateManager.requestBadgePermission()
			}
		}
		.onChange(of: pairingCore.installedAppsState) { state in
			// An inventory query can complete after the startup refresh has
			// timed out and published Signed fallback. Promote it to the
			// authoritative update snapshot without opening the Apps tab.
			guard case .loaded = state,
				!sourcesViewModel.isRefreshing,
				!updateManager.isRepositoryRefreshInProgress else { return }
			let configuredURLs = Set(
				Storage.shared.getSources().compactMap { $0.sourceURL?.absoluteString }
			)
			let activeSources = sourcesViewModel.sources.filter { source, _ in
				guard let url = source.sourceURL?.absoluteString else { return false }
				return configuredURLs.contains(url)
			}
			let loadedURLs = Set(
				activeSources.keys.compactMap { $0.sourceURL?.absoluteString }
			)
			guard configuredURLs == loadedURLs else { return }
			updateManager.refresh(repositories: Array(activeSources.values))
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

// A separate window-level badge layer avoids Liquid Glass clipping. The
// coordinator owns one badge per window and follows the frontmost visible
// avatar anchor, rather than leaving independent UILabels behind on pushes.
private final class ZagProfileBadgeCoordinator {
    static let shared = ZagProfileBadgeCoordinator()
    private struct Entry {
        weak var anchor: UIView?
        var count: Int
        var hidden: Bool
    }
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var labels: [ObjectIdentifier: UILabel] = [:]
    private var visibleStates: [ObjectIdentifier: Bool] = [:]
    private var updatesSheetPresented = false
    private var importBannerPresented = false
    private var launchSplashVisible = ZagSplashPreferences.isEnabled
    // The avatar can move when iOS inserts a temporary transfer banner.
    // Window-level labels must follow its presentation position, not only
    // SwiftUI layout passes (which may not run during ancestor animation).
    private var trackingLink: CADisplayLink?
    private var stableFrames = 0
    private var lastFrames: [ObjectIdentifier: CGRect] = [:]

    private func ensureTracking() {
        guard trackingLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(trackBadgePosition))
        link.add(to: .main, forMode: .common)
        trackingLink = link
        stableFrames = 0
    }

    @objc private func trackBadgePosition() {
        refresh()
    }

    private init() {
        NotificationCenter.default.addObserver(
            forName: .zagUpdatesSheetVisibilityDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            self.updatesSheetPresented = notification.userInfo?["presented"] as? Bool ?? false
            self.refresh()
        }
        NotificationCenter.default.addObserver(
            forName: Notification.Name("ZagStore.importBannerVisibilityDidChange"), object: nil, queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            self.importBannerPresented = notification.userInfo?["visible"] as? Bool ?? false
            self.refresh()
        }
        NotificationCenter.default.addObserver(
            forName: .zagLaunchSplashVisibilityDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            self.launchSplashVisible = notification.userInfo?["visible"] as? Bool ?? false
            self.refresh()
        }
    }

    private func setBadgeVisible(_ visible: Bool, for key: ObjectIdentifier, label: UILabel) {
        guard visibleStates[key] != visible else { return }
        visibleStates[key] = visible
        label.isHidden = false
        UIView.animate(withDuration: 0.34, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut]) {
            label.alpha = visible ? 1 : 0
        }
    }

    func update(_ anchor: UIView, count: Int, hidden: Bool) {
        entries[ObjectIdentifier(anchor)] = Entry(anchor: anchor, count: count, hidden: hidden)
        ensureTracking()
        refresh()
    }
    func remove(_ anchor: UIView) {
        entries.removeValue(forKey: ObjectIdentifier(anchor))
        refresh()
    }
    func refresh() {
        entries = entries.filter { $0.value.anchor != nil }
        let windows = Set(entries.values.compactMap { $0.anchor?.window }.map { ObjectIdentifier($0) })
        for (key, label) in labels where !windows.contains(key) {
            label.removeFromSuperview()
            labels.removeValue(forKey: key)
            visibleStates.removeValue(forKey: key)
        }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                let key = ObjectIdentifier(window)
                let candidates = entries.values.compactMap { entry -> (UIView, Entry, CGRect)? in
                    guard let anchor = entry.anchor, anchor.window === window,
                          !anchor.isHidden, anchor.alpha > 0.01,
                          anchor.bounds.width > 0, anchor.bounds.height > 0 else { return nil }
                    let rect = anchor.convert(anchor.bounds, to: window)
                    guard rect.intersects(window.bounds) else { return nil }
                    return (anchor, entry, rect)
                }
                // Pushed navigation pages can coexist briefly with the source.
                // The rightmost visible anchor wins, and only one badge is drawn.
                guard let chosen = candidates.max(by: { a, b in
                    if abs(a.2.maxX - b.2.maxX) > 1 { return a.2.maxX < b.2.maxX }
                    return a.2.minY > b.2.minY
                }) else {
                    if let label = labels[key] { setBadgeVisible(false, for: key, label: label) }
                    continue
                }
                let label: UILabel
                if let existing = labels[key] {
                    label = existing
                } else {
                    label = UILabel()
                    label.alpha = 0
                    label.textAlignment = .center
                    label.textColor = .white
                    label.font = .systemFont(ofSize: 13, weight: .regular)
                    label.backgroundColor = UIColor(displayP3Red: 1, green: 0.12, blue: 0.16, alpha: 1)
                    label.layer.cornerRadius = 9
                    label.layer.masksToBounds = true
                    label.isUserInteractionEnabled = false
                    window.addSubview(label)
                    labels[key] = label
                }
                let count = chosen.1.count
                label.text = count.description
                setBadgeVisible(count > 0 && !chosen.1.hidden && !updatesSheetPresented && !importBannerPresented && !launchSplashVisible, for: key, label: label)
                let width = max(23.5, CGFloat(count.description.count * 8) + 8.5)
                let targetFrame = CGRect(x: chosen.2.maxX - width + 7,
                                         y: chosen.2.minY - 7, width: width, height: 18)
                if label.frame != targetFrame {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    label.frame = targetFrame
                    CATransaction.commit()
                    stableFrames = 0
                }
                lastFrames[key] = targetFrame
                window.bringSubviewToFront(label)
            }
        }
        // Track geometry for a short settling window after each SwiftUI
        // update. No permanent display link runs while the interface is idle.
        if trackingLink != nil {
            stableFrames += 1
            if stableFrames > 24 {
                trackingLink?.invalidate()
                trackingLink = nil
            }
        }
    }
}

private struct ZagProfileBadgeAnchor: UIViewRepresentable {
    let count: Int
    let hidden: Bool
    func makeUIView(context: Context) -> ZagProfileBadgeAnchorView {
        ZagProfileBadgeAnchorView()
    }
    func updateUIView(_ view: ZagProfileBadgeAnchorView, context: Context) {
        view.count = count
        view.hiddenBadge = hidden
        ZagProfileBadgeCoordinator.shared.update(view, count: count, hidden: hidden)
    }
}

private final class ZagProfileBadgeAnchorView: UIView {
    var count = 0
    var hiddenBadge = false
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { ZagProfileBadgeCoordinator.shared.remove(self) }
        else { ZagProfileBadgeCoordinator.shared.update(self, count: count, hidden: hiddenBadge) }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        ZagProfileBadgeCoordinator.shared.refresh()
    }
    deinit { ZagProfileBadgeCoordinator.shared.remove(self) }
}

private struct ZagCircularToolbarBorder: ViewModifier {
	@ViewBuilder
	func body(content: Content) -> some View {
		if #available(iOS 17.0, *) {
			content.buttonBorderShape(.circle)
		} else {
			content
		}
	}
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
				.background {
                    ZagProfileBadgeAnchor(count: updateManager.updateCount,
                                          hidden: isAccountPresenting)
                }
		}
		.buttonStyle(ZagProfilePressStyle())
		.modifier(ZagCircularToolbarBorder())
		.tint(.primary)
		.contentShape(Circle())
		.accessibilityLabel("Account and App Updates")
		.onReceive(NotificationCenter.default.publisher(for: .zagProfileAvatarDidChange)) { _ in
			avatarRevision = UUID()
		}
		.sheet(isPresented: $isAccountPresenting) { ZagAccountPopup(onClose: { isAccountPresenting = false }) }
	}
}

struct ZagGlobalProfileAvatar: View {
    let revision: UUID
    var animatedBorder: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var borderRotation = false

    private let borderSpectrum: [Color] = [
        Color(red: 0.00, green: 0.86, blue: 1.00),
        Color(red: 0.05, green: 0.37, blue: 1.00),
        Color(red: 0.42, green: 0.18, blue: 1.00),
        Color(red: 0.95, green: 0.16, blue: 0.89),
        Color(red: 0.00, green: 0.86, blue: 1.00)
    ]

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
        .overlay {
            if animatedBorder {
                Circle().strokeBorder(
                    AngularGradient(colors: borderSpectrum, center: .center,
                                    angle: .degrees(borderRotation ? 360 : 0)),
                    lineWidth: 1.1
                )
            }
        }
        .onAppear {
            guard animatedBorder && !reduceMotion else { return }
            withAnimation(.linear(duration: 5).repeatForever(autoreverses: false)) {
                borderRotation = true
            }
        }
    }
}

struct ZagAccountPopup: View {
    let onClose: () -> Void
    @ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject private var selfUpdateCoordinator = ZagSelfUpdateCoordinator.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("Feather.userTintColor") private var themeColorHex: String = "#0090FF"
    @State private var avatarRevision = UUID()
    @State private var accountPath: [AccountDestination] = []

    private enum AccountDestination: Hashable {
        case profile, updates, certificates, installation, signing, notifications, devices, activity, selfUpdate, settings
    }

    private var themeTint: Color { Color(hex: themeColorHex) }

    var body: some View {
        NavigationStack(path: $accountPath) {
            Form {
                Section {
                    NavigationLink(value: AccountDestination.profile) {
                        HStack(spacing: 8) {
                            ZagGlobalProfileAvatar(revision: avatarRevision)
                                .frame(width: 54, height: 54)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Petar Zagorski")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(.primary)
                                Text("Account info and settings")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 0)
                    }
                    HStack(spacing: 8) {
                        Image(uiImage: ZagSourcesTabIcon.image)
                            .resizable()
                            .renderingMode(.template)
                            .interpolation(.high)
                            .scaledToFit()
                            .foregroundStyle(themeTint)
                            .frame(width: 14, height: 14)
                            .frame(width: 30, height: 30)
                            .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                            .frame(width: 54)
                        Text("Account Type")
                        Spacer()
                        Text("Guest")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                Section {
                    NavigationLink(value: AccountDestination.updates) {
                        HStack {
                            Text("App Updates")
                            Spacer()
                            if updateManager.updateCount > 0 {
                                Text(updateManager.updateCount.description)
                                    .font(.system(size: 20, weight: .regular))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5.75)
                                    .frame(minWidth: 27.5, minHeight: 26)
                                    .background(Color(red: 1, green: 66.0 / 255.0, blue: 68.0 / 255.0), in: Capsule())
                            }
                        }
                    }
                    NavigationLink(value: AccountDestination.certificates) {
                        Text("Certificates")
                    }
                    NavigationLink(value: AccountDestination.installation) {
                        Text("Installation")
                    }
                    NavigationLink(value: AccountDestination.signing) {
                        Text("Signing")
                    }
                    NavigationLink(value: AccountDestination.devices) {
                        Text("Devices")
                    }
                    NavigationLink(value: AccountDestination.activity) {
                        Text("Activity")
                    }
                    NavigationLink(value: AccountDestination.notifications) {
                        Text("Notifications")
                    }
                }
                Section {
                    NavigationLink(value: AccountDestination.selfUpdate) {
                        HStack(spacing: 10) {
                            ZagSelfUpdateRotatingIcon(isAnimating: selfUpdateCoordinator.availableRelease != nil)
                                .frame(width: 28, height: 28)
                                .foregroundStyle(themeTint)
                            Text("Zag Store Update").foregroundStyle(themeTint)
                            Spacer(minLength: 8)
                            if selfUpdateCoordinator.availableRelease != nil {
                                ZagSelfUpdateSpectrumDot(diameter: 10)
                            }
                        }
                    }
                    NavigationLink(value: AccountDestination.settings) {
                        HStack(spacing: 10) {
                            Image(systemName: "gear")
                                .frame(width: 28, height: 28)
                                .foregroundStyle(themeTint)
                            Text("Zag Store Settings").foregroundStyle(themeTint)
                        }
                    }
                }
            }
            .navigationTitle("")
            .toolbar {
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .topBarLeading) {
                        ZagAccountToolbarHeading()
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .topBarLeading) {
                        ZagAccountToolbarHeading()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
            .navigationDestination(for: AccountDestination.self) { destination in
                Group {
                    switch destination {
                    case .profile: ZagAccountAvatarEditor()
                    case .updates: ZagUpdatesPopup(updates: updateManager.updates, embeddedInAccountNavigation: true)
                    case .certificates: CertificatesView()
                    case .installation: InstallationView()
                    case .signing: ConfigurationView()
                    case .notifications: ZagAccountNotificationsView()
                    case .devices: ZagDevicesPage().tint(themeTint)
                    case .activity: TabEnum.view(for: .activity).tint(themeTint)
                    case .selfUpdate: ZagSelfUpdateStatusView()
                    case .settings:
                        SettingsView(
                            embeddedInAccountNavigation: true,
                            onAccountBack: {
                                if !accountPath.isEmpty { accountPath.removeLast() }
                            }
                        )
                        .navigationBarBackButtonHidden(true)
                    }
                }
                .toolbar {
                    if destination != .settings {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(action: onClose) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 16, weight: .semibold))
                            }
                            .accessibilityLabel("Close")
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .toggleStyle(ZagThemeTintToggleStyle())
        .environment(\.zagInsideAccountPopup, true)
        .environment(\.zagAccountClose, onClose)
        .onReceive(NotificationCenter.default.publisher(for: .zagProfileAvatarDidChange)) { _ in
            avatarRevision = UUID()
        }
    }
}

private struct ZagAccountToolbarHeading: View {
    var body: some View {
        HStack(spacing: 9) {
            Image("ZagAccountIconDark")
                .resizable()
                .scaledToFill()
                .frame(width: 27, height: 27)
                .clipShape(Circle())
            Text("Zag Account")
                .font(.headline)
                .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }
}

private struct ZagAccountNotificationsView: View {
    @AppStorage(UpdateManager.updateNotificationsEnabledKey) private var updateNotificationsEnabled = false

    var body: some View {
        Form {
            Section {
                Toggle("Update Notifications", isOn: $updateNotificationsEnabled)
                    .onChange(of: updateNotificationsEnabled) { enabled in
                        guard enabled else { return }
                        Task {
                            let granted = await UpdateManager.shared.requestUpdateNotificationPermission()
                            if !granted {
                                await MainActor.run { updateNotificationsEnabled = false }
                            }
                        }
                    }
            } footer: {
                Text("Get notified when Zag Store discovers new app versions.")
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ZagAccountAvatarEditor: View {
    @State private var selection: PhotosPickerItem?
    @State private var revision = UUID()
    @AppStorage("Feather.userTintColor") private var themeColorHex: String = "#0090FF"

    private var themeTint: Color { Color(hex: themeColorHex) }

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    ZagGlobalProfileAvatar(revision: revision)
                        .frame(width: 112, height: 112)
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } header: {
                Text("Profile Avatar")
            }

            // Keep the avatar preview outside the grouped actions so the
            // actions receive their native rounded top corners, without a
            // divider between the preview and the first button.
            Section {
                PhotosPicker(selection: $selection, matching: .images) {
                    Label {
                        Text("Choose Profile Avatar")
                    } icon: {
                        Image(systemName: "photo").foregroundStyle(themeTint)
                    }
                }
                .onChange(of: selection) { item in
                    guard let item else { return }
                    Task {
                        if let data = try? await item.loadTransferable(type: Data.self) {
                            try? ZagProfileAvatarStore.save(data)
                            await MainActor.run {
                                revision = UUID()
                                selection = nil
                            }
                        }
                    }
                }
                if ZagProfileAvatarStore.customImage() != nil {
                    Button(role: .destructive) {
                        ZagProfileAvatarStore.removeCustomImage()
                        revision = UUID()
                    } label: {
                        Label {
                            Text("Use Default Avatar")
                        } icon: {
                            Image(systemName: "arrow.counterclockwise").foregroundStyle(themeTint)
                        }
                    }
                }
            }
        }
        .navigationTitle("Account Info")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Account Info")
                    .font(.headline)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .zagProfileAvatarDidChange)) { _ in
            revision = UUID()
        }
    }
}


struct ZagLocalVPNToolbarStatus: View {
    @StateObject private var monitor = ZagLocalVPNMonitor.shared
    @State private var showDetails = false

    private var indicator: ZagLinkIndicator { monitor.model.indicator }

    private var statusColor: Color {
        switch indicator {
        case .checking, .off: return .secondary
        case .warning: return .orange
        case .on: return Color(uiColor: UIColor(displayP3Red: 0, green: 1, blue: 0.22, alpha: 1))
        }
    }

    private var statusText: String {
        switch indicator {
        case .checking: return "…"
        case .off: return "—"
        case .warning: return "!"
        case .on: return "ON"
        }
    }

    private var accessibilityText: String {
        switch indicator {
        case .checking: return "Checking local VPN connection"
        case .off: return "Local VPN not connected or status unknown"
        case .warning: return "Local VPN connected, device connection failed"
        case .on: return "Local VPN device connection reachable"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("LOCAL")
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            Text("VPN")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            HStack(spacing: 3) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 4, height: 4)
                Text(statusText)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(statusColor)
            }
        }
        .frame(width: 44, height: 39)
        .accessibilityLabel(accessibilityText)
        .contentShape(Rectangle())
        .onTapGesture { showDetails = true }
        .accessibilityAddTraits(.isButton)
        .popover(isPresented: $showDetails, arrowEdge: .top) {
            ZagLocalVPNDetailsView()
                .presentationCompactAdaptation(.popover)
        }
        .onAppear { monitor.startIfNeeded() }
    }
}

private struct ZagLocalVPNDetailsView: View {
    @ObservedObject private var monitor = ZagLocalVPNMonitor.shared

    private var model: ZagDeviceLinkModel { monitor.model }

    private var tunnelText: (String, Color) {
        switch model.tunnel {
        case .unknown: return ("Unknown", .secondary)
        case .interfaceDetected: return ("Detected, no answer", .secondary)
        case .operational: return ("Connected", .green)
        case .disconnected: return ("Not connected", .secondary)
        }
    }

    private var serviceText: (String, Color) {
        if model.checking, model.service == .notChecked { return ("Checking…", .secondary) }
        switch model.service {
        case .notChecked: return ("Not checked", .secondary)
        case .reachable: return ("Reachable", .green)
        case .unreachable(let failure, _): return (failure.summary, .orange)
        case .noResponse: return ("No response", .secondary)
        }
    }

    private var pairingText: (String, Color) {
        switch model.pairing {
        case .notChecked: return ("Not checked", .secondary)
        case .verified: return ("Verified", .green)
        case .failed: return ("Failed", .orange)
        case .awaitingRevalidation: return ("Earlier success; recheck", .secondary)
        }
    }

    private var guidance: String? {
        if case .failed(let kind, _) = model.pairing, model.indicator == .warning {
            return ZagRPPairingFailure.explanation(kind)
        }
        switch model.service {
        case .noResponse:
            return model.tunnel == .disconnected
                ? "LocalDevVPN does not appear to be connected. Connect it, then return to Zag Store."
                : "Nothing answered through the tunnel. Reconnect LocalDevVPN and refresh."
        case .unreachable:
            return "The tunnel works, but the iPhone did not accept the RemotePairing connection. Run the RPPairing health check for details."
        default:
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Local VPN", systemImage: "network")
                    .font(.headline)
                Spacer()
                Button {
                    monitor.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.checking)
                .accessibilityLabel("Refresh Local VPN status")
            }
            Divider()
            LabeledContent("Tunnel") {
                Text(tunnelText.0).foregroundStyle(tunnelText.1)
            }
            LabeledContent("Device service") {
                Text(serviceText.0)
                    .foregroundStyle(serviceText.1)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("RPPairing") {
                Text(pairingText.0).foregroundStyle(pairingText.1)
            }
            LabeledContent("Last successful check") {
                if let date = monitor.lastSuccess {
                    Text(date, style: .time)
                } else {
                    Text("None").foregroundStyle(.secondary)
                }
            }
            LabeledContent("Response time") {
                if let milliseconds = model.lastResponseMilliseconds {
                    Text("\(milliseconds) ms")
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            if let guidance {
                Text(guidance)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Checks that the iPhone accepts the RemotePairing connection through the local tunnel, on Wi-Fi or mobile data. RPPairing shows the latest health check or installation.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 300)
    }
}

private struct ZagSelfUpdateRotatingIcon: View {
    let isAnimating: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 120.0, paused: !isAnimating || reduceMotion)) { context in
            let angle = isAnimating && !reduceMotion
                ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3.0) * 120.0
                : 0.0
            Image(systemName: "arrow.triangle.2.circlepath")
                .rotationEffect(.degrees(angle))
        }
        .accessibilityHidden(true)
    }
}
