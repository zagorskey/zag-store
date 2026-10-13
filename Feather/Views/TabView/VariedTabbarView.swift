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
		.onAppear {
            updateDockTint()
        }
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

    func update(_ anchor: UIView, count: Int, hidden: Bool) {
        entries[ObjectIdentifier(anchor)] = Entry(anchor: anchor, count: count, hidden: hidden)
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
                    labels[key]?.isHidden = true
                    continue
                }
                let label: UILabel
                if let existing = labels[key] {
                    label = existing
                } else {
                    label = UILabel()
                    label.textAlignment = .center
                    label.textColor = .white
                    label.font = .systemFont(ofSize: 12, weight: .regular)
                    label.backgroundColor = UIColor(displayP3Red: 1, green: 0.12, blue: 0.16, alpha: 1)
                    label.layer.cornerRadius = 10
                    label.layer.masksToBounds = true
                    label.isUserInteractionEnabled = false
                    window.addSubview(label)
                    labels[key] = label
                }
                let count = chosen.1.count
                label.text = count.description
                label.isHidden = count == 0 || chosen.1.hidden
                let width = max(20, CGFloat(count.description.count * 8 + 10))
                label.frame = CGRect(x: chosen.2.maxX - width + 7,
                                     y: chosen.2.minY - 10, width: width, height: 20)
                window.bringSubviewToFront(label)
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
		.sheet(isPresented: $isAccountPresenting) { ZagAccountPopup() }
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
    @ObservedObject private var updateManager = UpdateManager.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("Feather.userTintColor") private var themeColorHex: String = "#3F8EF7"
    @State private var avatarRevision = UUID()

    private var themeTint: Color { ZagWideGamutTint.color(hex: themeColorHex) }

    private var accountIcon: UIImage? {
        if let image = UIImage(named: "ZagAccountIconDark") { return image }
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let names = primary["CFBundleIconFiles"] as? [String] else { return nil }
        return names.reversed().compactMap { UIImage(named: $0) }.first
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        ZagAccountAvatarEditor()
                    } label: {
                        HStack(spacing: 14) {
                            ZagGlobalProfileAvatar(revision: avatarRevision, animatedBorder: true)
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
                        .padding(.vertical, 7)
                    }
                }
                Section {
                    NavigationLink {
                        ZagUpdatesPopup(updates: updateManager.updates)
                    } label: {
                        HStack {
                            Text("App Updates")
                            Spacer()
                            if updateManager.updateCount > 0 {
                                Text(updateManager.updateCount.description)
                                    .font(.body)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8)
                                    .frame(minWidth: 29, minHeight: 25)
                                    .background(Color(uiColor: UIColor(displayP3Red: 1, green: 0.23, blue: 0.28, alpha: 1)), in: Capsule())
                            }
                        }
                    }
                }
                Section {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label {
                            Text("Zag Store Settings").foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: "gearshape").foregroundStyle(themeTint)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 9) {
                    Group {
                        if let accountIcon {
                            Image(uiImage: accountIcon).resizable().scaledToFill()
                        } else {
                            Image(systemName: "app.fill")
                                .resizable().scaledToFit()
                                .foregroundStyle(themeTint)
                        }
                    }
                    .frame(width: 27, height: 27)
                    .clipShape(Circle())
                    Text("Zag Account")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()

                }
                .padding(.horizontal, 20)
                .frame(height: 48)
                .padding(.top, 6)
            }
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

private struct ZagAccountAvatarEditor: View {
    @State private var selection: PhotosPickerItem?
    @State private var revision = UUID()

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
                PhotosPicker(selection: $selection, matching: .images) {
                    Label("Choose Profile Avatar", systemImage: "photo")
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
                        Label("Use Default Avatar", systemImage: "arrow.counterclockwise")
                    }
                }
            } header: {
                Text("Profile Avatar")
            }
        }
        .navigationTitle("Profile Avatar")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .zagProfileAvatarDidChange)) { _ in
            revision = UUID()
        }
    }
}


// Synchronizes the one-shot network callback and timeout across queues.
private final class ZagVPNCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        return true
    }
}

// Reachability verifies the device-services path, not another app's VPN manager.
// A failed probe is inconclusive and must never be displayed as confirmed OFF.
@MainActor
private final class ZagLocalVPNReachability: ObservableObject {
    static let shared = ZagLocalVPNReachability()

    @Published private(set) var reachable: Bool? = nil
    @Published private(set) var checking = false
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var lastResponseMilliseconds: Int?

    private var observers: [NSObjectProtocol] = []
    private var refreshTimer: Timer?
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "zag.localvpn.path")
    private var started = false
    private var active = true

    private init() {}

    func startIfNeeded() {
        guard !started else { return }
        started = true
        active = UIApplication.shared.applicationState == .active

        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.active = true
                self?.refresh()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.active = false }
        })

        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.active else { return }
                self.reachable = nil
                self.refresh()
            }
        }
        pathMonitor.start(queue: pathQueue)

        // One shared timer, independent of the number of toolbar instances.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.active else { return }
                self.refresh()
            }
        }
        if active { refresh() }
    }

    func refresh() {
        guard active, !checking else { return }
        checking = true
        let startedAt = ProcessInfo.processInfo.systemUptime
        let connection = NWConnection(host: "10.7.0.1", port: 62078, using: .tcp)
        let queue = DispatchQueue(label: "zag.localvpn.reachability")
        let completionGate = ZagVPNCompletionGate()
        @Sendable nonisolated func complete(_ success: Bool) {
            guard completionGate.claim() else { return }
            connection.cancel()
            Task { @MainActor in
                self.reachable = success ? true : nil
                if success {
                    self.lastSuccess = Date()
                    self.lastResponseMilliseconds = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
                }
                self.checking = false
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: complete(true)
            case .failed, .cancelled: complete(false)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 2) { complete(false) }
    }
}

struct ZagLocalVPNToolbarStatus: View {
    @StateObject private var monitor = ZagLocalVPNReachability.shared
    @State private var showDetails = false

    private var statusColor: Color {
        if monitor.checking { return .secondary }
        if monitor.reachable == true {
            return Color(uiColor: UIColor(displayP3Red: 0, green: 1, blue: 0.22, alpha: 1))
        }
        return .secondary
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
                Text(monitor.checking ? "…" : (monitor.reachable == true ? "ON" : "—"))
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(statusColor)
            }
        }
        .frame(width: 44, height: 39)
        .accessibilityLabel(monitor.checking ? "Checking local VPN connection" :
            (monitor.reachable == true ? "Local VPN device services reachable" : "Local VPN status unknown"))
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
    @ObservedObject private var monitor = ZagLocalVPNReachability.shared

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
                .disabled(monitor.checking)
                .accessibilityLabel("Refresh Local VPN status")
            }
            Divider()
            LabeledContent("Connection") {
                Text(monitor.checking ? "Checking…" : (monitor.reachable == true ? "Reachable" : "Unknown"))
                    .foregroundStyle(monitor.reachable == true && !monitor.checking ? .green : .secondary)
            }
            LabeledContent("Last successful check") {
                if let date = monitor.lastSuccess {
                    Text(date, style: .time)
                } else {
                    Text("None").foregroundStyle(.secondary)
                }
            }
            LabeledContent("Response time") {
                if let milliseconds = monitor.lastResponseMilliseconds {
                    Text("\(milliseconds) ms")
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            Text("Checks whether iPhone device services are reachable through the local tunnel. This does not read LocalDevVPN's own connection state.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 300)
    }
}
