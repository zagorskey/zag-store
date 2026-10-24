//
//  SourceAppsView.swift
//  Feather
//
//  Created by samara on 1.05.2025.
//

import SwiftUI
import AltSourceKit
import NimbleViews
import UIKit
import ObjectiveC.runtime


// Keep this toolbar in a small modifier to avoid inflating the large
// repository view's SwiftUI type-checking expression.
private struct ZagRepositoryActionsToolbar<SortContent: View>: ViewModifier {
    let sortActions: () -> SortContent

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                sortActions()
                ZagProfileToolbarButton()
                    .tint(.primary)
                    .padding(.trailing, -2)
            }
        }
    }
}

// Visual preview only. Replace the unconditional display with a trusted
// verification-registry lookup when Zag Verified launches.
private struct ZagRepositoryShield: View {
    var body: some View {
        Image(systemName: "shield.fill")
            .font(.system(size: 24, weight: .regular))
            .foregroundStyle(Color(uiColor: UIColor(displayP3Red: 0, green: 1, blue: 0, alpha: 1)))
            .overlay {
                Image(uiImage: ZagSourcesTabIcon.image)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .foregroundStyle(Color(uiColor: UIColor(displayP3Red: 0, green: 0.20, blue: 0.04, alpha: 1)))
                    .frame(width: 15, height: 15)
                    .offset(y: -1)
            }
            .frame(width: 25, height: 27)
            .accessibilityLabel("Zag shield preview")
    }
}

private struct ZagRepositoryIconPill: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.tint)
            .frame(width: 32, height: 25)
            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.75))
            .contentShape(Capsule())
    }
}

// Observe the actual list scroll view rather than a SwiftUI row preference.
// List row geometry can be cached/recycled and is not a reliable scroll signal.
private struct ZagRepositoryScrollObserver: UIViewRepresentable {
    @Binding var scrolled: Bool

    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.onScroll = { scrolled = $0 }
        return view
    }

    func updateUIView(_ view: Probe, context: Context) {
        view.onScroll = { scrolled = $0 }
        DispatchQueue.main.async { [weak view] in view?.attach() }
    }

    final class Probe: UIView {
        var onScroll: ((Bool) -> Void)?
        private var observation: NSKeyValueObservation?
        private weak var observedScrollView: UIScrollView?
        private var initialOffset: CGFloat?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                observation = nil
                observedScrollView = nil
                initialOffset = nil
            } else {
                DispatchQueue.main.async { [weak self] in self?.attach() }
            }
        }

        func attach() {
            guard window != nil else { return }
            // The probe is attached to the list's background; locate the
            // nearest list scroll view within its hosting view hierarchy.
            var node: UIView? = superview
            var scroll: UIScrollView?
            while let current = node, scroll == nil {
                scroll = current.subviews.compactMap { findScrollView(in: $0) }.first
                node = current.superview
            }
            guard let scroll, scroll !== observedScrollView else { return }
            observation = nil
            observedScrollView = scroll
            initialOffset = scroll.contentOffset.y
            observation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] scroll, _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let origin = self.initialOffset ?? scroll.contentOffset.y
                    self.onScroll?(scroll.contentOffset.y - origin > 12)
                }
            }
        }

        private func findScrollView(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView,
               !(scroll is UITextView),
               scroll.isScrollEnabled {
                return scroll
            }
            for child in view.subviews {
                if let scroll = findScrollView(in: child) { return scroll }
            }
            return nil
        }
    }
}

private struct ZagRepositoryFeaturedPill: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotating = false

    private let spectrum: [Color] = [
        Color(red: 0.00, green: 0.86, blue: 1.00),
        Color(red: 0.05, green: 0.37, blue: 1.00),
        Color(red: 0.42, green: 0.18, blue: 1.00),
        Color(red: 0.95, green: 0.16, blue: 0.89),
        Color(red: 0.00, green: 0.86, blue: 1.00)
    ]

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(uiImage: ZagSourcesTabIcon.image)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 12, height: 12)
                .frame(width: 12, height: 14, alignment: .center)
                .accessibilityHidden(true)
            Text("Featured")
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
        .overlay {
            Capsule().strokeBorder(
                AngularGradient(colors: spectrum, center: .center, angle: .degrees(rotating ? 360 : 0)),
                lineWidth: 1.1
            )
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 5).repeatForever(autoreverses: false)) {
                rotating = true
            }
        }
        .accessibilityLabel("Zag Featured repository")
    }
}

// MARK: - System Dictation Lifecycle Bridge

private extension Notification.Name {
	static let zagDictationDidStart = Notification.Name("ZagDictationDidStart")
	static let zagDictationDidEnd = Notification.Name("ZagDictationDidEnd")
}

private extension NSObject {
	@objc dynamic func zag_setupForDictationStart() {
		// After method exchange this calls UIKit's original implementation.
		// Starting dictation is not the point where App Store hides its trailing mic.
		zag_setupForDictationStart()
	}

	@objc dynamic func zag_stopDictation() {
		zag_stopDictation()
		NotificationCenter.default.post(name: .zagDictationDidEnd, object: nil)
	}

	@objc dynamic func zag_cancelDictation() {
		zag_cancelDictation()
		NotificationCenter.default.post(name: .zagDictationDidEnd, object: nil)
	}
}

private enum ZagSystemDictationLifecycle {
	private static var installed = false

	static func install() {
		guard !installed,
			  let dictationClass = NSClassFromString("UIDictationController")
		else { return }

		installed = true
		exchange(
			on: dictationClass,
			original: NSSelectorFromString("setupForDictationStart"),
			replacement: #selector(NSObject.zag_setupForDictationStart)
		)
		exchange(
			on: dictationClass,
			original: NSSelectorFromString("stopDictation"),
			replacement: #selector(NSObject.zag_stopDictation)
		)
		exchange(
			on: dictationClass,
			original: NSSelectorFromString("cancelDictation"),
			replacement: #selector(NSObject.zag_cancelDictation)
		)
	}

	private static func exchange(
		on cls: AnyClass,
		original: Selector,
		replacement: Selector
	) {
		guard
			let originalMethod = class_getInstanceMethod(cls, original),
			let replacementMethod = class_getInstanceMethod(NSObject.self, replacement)
		else { return }

		class_addMethod(
			cls,
			replacement,
			method_getImplementation(replacementMethod),
			method_getTypeEncoding(replacementMethod)
		)

		guard
			let installedReplacement = class_getInstanceMethod(cls, replacement)
		else { return }

		method_exchangeImplementations(originalMethod, installedReplacement)
	}
}

// MARK: - Native Search Microphone

struct ZagNativeSearchMicInstaller: UIViewRepresentable {
	let isAvailable: Bool
	let action: () -> Void
	var prompt: String
	var activePrompt: String? = nil

	func makeCoordinator() -> Coordinator {
		Coordinator(
			action: action,
			prompt: prompt,
			activePrompt: activePrompt
		)
	}

	func makeUIView(context: Context) -> UIView {
		let view = UIView(frame: .zero)
		view.isUserInteractionEnabled = false
		DispatchQueue.main.async {
			context.coordinator.install(from: view, isAvailable: isAvailable)
		}
		return view
	}

	func updateUIView(_ uiView: UIView, context: Context) {
		context.coordinator.action = action
		context.coordinator.prompt = prompt
		context.coordinator.activePrompt = activePrompt
		DispatchQueue.main.async {
			context.coordinator.install(from: uiView, isAvailable: isAvailable)
		}
	}

    // Shared native accessory used by Apps, Sources, and pinned internal search.
    static func makeMicrophoneButton(target: Any?, action: Selector, pointSize: CGFloat = 20) -> UIButton {
        let mic = UIButton(type: .system)
        mic.setImage(
            UIImage(
                systemName: "mic",
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: pointSize,
                    weight: .regular,
                    scale: .medium
                )
            ),
            for: .normal
        )
        mic.tintColor = .label
        mic.frame = CGRect(x: 0, y: 0, width: 36, height: 36)
        mic.addTarget(target, action: action, for: .touchUpInside)
        mic.accessibilityLabel = "Start Dictation"
        return mic
    }

	final class Coordinator: NSObject {
		var action: () -> Void
		var prompt: String
		var activePrompt: String?
		private weak var installedField: UISearchTextField?
		private weak var button: UIButton?
		private var dictationObserversInstalled = false
		private var yieldingToNativeClearButton = false

		init(
			action: @escaping () -> Void,
			prompt: String,
			activePrompt: String?
		) {
			self.action = action
			self.prompt = prompt
			self.activePrompt = activePrompt
		}

		func install(from anchor: UIView, isAvailable: Bool) {
			guard let window = anchor.window else {
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
					self.install(from: anchor, isAvailable: isAvailable)
				}
				return
			}

			guard let field = Self.findSearchField(in: window) else { return }

			applyPlaceholderStyle(to: field)

			if yieldingToNativeClearButton {
				if !(field.text ?? "").isEmpty {
					if field.rightView === button {
						field.rightView = nil
					}
					return
				}
				yieldingToNativeClearButton = false
			}

			if installedField !== field || button == nil {
				let mic = ZagNativeSearchMicInstaller.makeMicrophoneButton(
                    target: self,
                    action: #selector(micPressed)
                )

				field.rightView = mic
				field.rightViewMode = .always
				field.removeTarget(self, action: #selector(searchTextChanged), for: .editingChanged)
				field.addTarget(self, action: #selector(searchTextChanged), for: .editingChanged)
				field.removeTarget(self, action: #selector(searchFocusBegan), for: .editingDidBegin)
				field.addTarget(self, action: #selector(searchFocusBegan), for: .editingDidBegin)
				field.removeTarget(self, action: #selector(searchFocusEnded), for: .editingDidEnd)
				field.addTarget(self, action: #selector(searchFocusEnded), for: .editingDidEnd)
				installedField = field
				button = mic
			}

			button?.tintColor = .label
			if button?.isUserInteractionEnabled != false {
				button?.alpha = isAvailable ? 1.0 : 0.45
			}
			button?.isEnabled = isAvailable

			installDictationObserversIfNeeded()
		}

		private func installDictationObserversIfNeeded() {
			guard !dictationObserversInstalled else { return }
			dictationObserversInstalled = true

			ZagSystemDictationLifecycle.install()

 			NotificationCenter.default.addObserver(
				self,
				selector: #selector(dictationEnded),
				name: .zagDictationDidEnd,
				object: nil
			)
		}

		@objc private func micPressed() {
			action()
		}

		@objc private func dictationStarted() {
			setMicVisible(false, animated: true)
		}

		@objc private func dictationEnded() {
            guard let field = installedField else { return }
            // Stopping system dictation yields the trailing accessory to
            // UIKit's clear control while the recognized query is nonempty.
            // If nothing was transcribed, bring the mic back immediately.
            if (field.text ?? "").isEmpty {
                yieldingToNativeClearButton = false
                if field.rightView !== button || button == nil {
                    installMic(in: field)
                } else {
                    setMicVisible(true, animated: true)
                }
                return
            }
            yieldingToNativeClearButton = true
            UIView.animate(
                withDuration: 0.16,
                delay: 0,
                options: [.beginFromCurrentState, .curveEaseInOut],
                animations: {
                    self.button?.alpha = 0
                    self.button?.transform = CGAffineTransform(scaleX: 0.82, y: 0.82)
                },
                completion: { _ in
                    if field.rightView === self.button {
                        field.rightView = nil
                    }
                    self.button = nil
                }
            )
        }

		@objc private func searchTextChanged(_ field: UISearchTextField) {
			guard yieldingToNativeClearButton, (field.text ?? "").isEmpty else { return }

			yieldingToNativeClearButton = false
			installMic(in: field)
		}

		private func installMic(in field: UISearchTextField) {
			let mic = UIButton(type: .system)
			mic.setImage(
				UIImage(
					systemName: "mic",
					withConfiguration: UIImage.SymbolConfiguration(
						pointSize: 20,
							weight: .regular,
							scale: .medium
					)
				),
				for: .normal
			)
			mic.tintColor = .label
			mic.frame = CGRect(x: 0, y: 0, width: 36, height: 36)
			mic.addTarget(self, action: #selector(micPressed), for: .touchUpInside)
			mic.accessibilityLabel = "Start Dictation"
			mic.alpha = 0
			mic.transform = CGAffineTransform(scaleX: 0.82, y: 0.82)

			field.rightView = mic
			field.rightViewMode = .always
			button = mic

			UIView.animate(
				withDuration: 0.2,
				delay: 0,
				options: [.beginFromCurrentState, .curveEaseInOut],
				animations: {
					mic.alpha = 1
					mic.transform = .identity
				}
			)
		}

		private func setMicVisible(_ visible: Bool, animated: Bool) {
			guard let button else { return }
			let changes = {
				button.alpha = visible ? 1.0 : 0.0
				button.transform = visible
					? .identity
					: CGAffineTransform(scaleX: 0.82, y: 0.82)
			}

			if animated {
				UIView.animate(
					withDuration: 0.2,
					delay: 0,
					options: [.beginFromCurrentState, .curveEaseInOut],
					animations: changes
				)
			} else {
				changes()
			}
			button.isUserInteractionEnabled = visible
		}

		@objc private func searchFocusBegan(_ field: UISearchTextField) {
			stabilizePlaceholder(in: field, focused: true)
		}

		@objc private func searchFocusEnded(_ field: UISearchTextField) {
			stabilizePlaceholder(in: field, focused: false)
		}

		private func stabilizePlaceholder(
			in field: UISearchTextField,
			focused: Bool
		) {
			// Native searchable mutates its text field several times while its
			// activation/collapse animation is running. Re-assert our prompt
			// during that short window so SwiftUI cannot flash the old value.
			for delay in [0.0, 0.03, 0.08, 0.16, 0.28] {
				DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak field] in
					guard let self, let field else { return }
					guard field.isFirstResponder == focused else { return }
					self.applyPlaceholderStyle(to: field, focused: focused)
				}
			}
		}

		private func applyPlaceholderStyle(
			to field: UISearchTextField,
			focused: Bool? = nil
		) {
			let isFocused = focused ?? field.isFirstResponder
			let text = isFocused ? (activePrompt ?? prompt) : prompt
			field.attributedPlaceholder = NSAttributedString(
				string: text,
				attributes: [
					.font: UIFont.systemFont(ofSize: 19, weight: .semibold),
					.foregroundColor: UIColor.placeholderText
				]
			)
		}

		private static func findSearchField(in view: UIView) -> UISearchTextField? {
			if let field = view as? UISearchTextField {
				return field
			}

			for subview in view.subviews {
				if let field = findSearchField(in: subview) {
					return field
				}
			}
			return nil
		}
	}
}

// MARK: - Native Search Focus Compatibility

struct ZagRepositorySearchFocusModifier: ViewModifier {
	let isFocused: FocusState<Bool>.Binding

	@ViewBuilder
	func body(content: Content) -> some View {
		if #available(iOS 18.0, *) {
			content.searchFocused(isFocused)
		} else {
			content
		}
	}
}

// MARK: - Extension: View (Enil)
extension SourceAppsView {
	enum SortOption: String, CaseIterable {
		case `default` = "default"
		case name
		case date
		
		var displayName: String {
			switch self {
			case .default:  .localized("Default")
			case .name: 	.localized("Name")
			case .date: 	.localized("Date")
			}
		}
	}
}

// MARK: - View
struct SourceAppsView: View {
	@AppStorage("Feather.sortOptionRawValue") private var _sortOptionRawValue: String = SortOption.default.rawValue
	@AppStorage("Feather.sortAscending") private var _sortAscending: Bool = true
	
	@State private var _sortOption: SortOption = .default
	@State private var _selectedRoute: SourceAppRoute?
	
	@State var isLoading = true
	@State var hasLoadedOnce = false
	@State private var _searchText = ""
	@State private var _repositoryScrolled = false
	@State private var _repositoryManifestBytes: Int64?
	@State private var _overviewCollapsed = false
	@State private var _appsCollapsed = false
	@State private var _detailsCollapsed = false
	@State private var _showRepositoryDetails = false
	@State private var _dictationAvailable = false
	@State private var _dictationStatus = "Dictation unavailable"
	@FocusState private var _searchFieldFocused: Bool

	private var _requestedSourcesAreAvailable: Bool {
		!object.isEmpty && object.allSatisfy { viewModel.sources[$0] != nil }
	}

	private var _navigationTitle: String {
		if object.count == 1 {
			"Repository"
		} else {
			"Sources: \(object.count)"
		}
	}
	
	var object: [AltSource]
	@ObservedObject var viewModel: SourcesViewModel
	@State private var _sources: [ASRepository]?
	
	// Use the same native scrolling list as Apps and Sources. UIKit's embedded
	// table did not participate in the navigation bar's scroll-edge transitions.
	private var repositoryEntries: [SourceAppRoute] {
		let all = (_sources ?? []).flatMap { source in
			source.apps.map { SourceAppRoute(source: source, app: $0) }
		}
		let filtered = _searchText.isEmpty ? all : all.filter { entry in
			let app = entry.app
			return (app.id?.localizedCaseInsensitiveContains(_searchText) ?? false)
				|| app.currentName.localizedCaseInsensitiveContains(_searchText)
				|| (app.currentDescription?.localizedCaseInsensitiveContains(_searchText) ?? false)
				|| (app.subtitle?.localizedCaseInsensitiveContains(_searchText) ?? false)
				|| (app.localizedDescription?.localizedCaseInsensitiveContains(_searchText) ?? false)
		}
		switch _sortOption {
		case .default:
			return _sortAscending ? filtered : Array(filtered.reversed())
		case .name:
			return filtered.sorted {
				let comparison = $0.app.currentName.localizedStandardCompare($1.app.currentName)
				return _sortAscending ? comparison == .orderedAscending : comparison == .orderedDescending
			}
		case .date:
			return filtered.sorted {
				let left = $0.app.currentDate?.date ?? .distantPast
				let right = $1.app.currentDate?.date ?? .distantPast
				return _sortAscending ? left < right : left > right
			}
		}
	}

	private var _repositoryURLs: [URL] {
		object.compactMap(\.sourceURL)
	}


	private var _repositoryActionPills: some View {
		HStack(spacing: 6) {
			if object.count == 1, let website = _sources?.first?.website {
				Button {
					UIApplication.open(website)
				} label: {
					Image(systemName: "globe")
				}
				.buttonStyle(.plain)
				.modifier(ZagRepositoryIconPill())
				.accessibilityLabel("Visit Website")
			}
			Button {
				UIPasteboard.general.string = _repositoryURLs.map(\.absoluteString).joined(separator: "\n")
			} label: {
				Image(systemName: "doc.on.doc")
					.font(.system(size: 11, weight: .medium))
			}
			.buttonStyle(.plain)
			.modifier(ZagRepositoryIconPill())
			.accessibilityLabel("Copy Repository URL")
			.disabled(_repositoryURLs.isEmpty)
			ShareLink(item: _repositoryURLs.map(\.absoluteString).joined(separator: "\n")) {
				Image(systemName: "square.and.arrow.up")
					.font(.system(size: 11, weight: .medium))
			}
			.buttonStyle(.plain)
			.modifier(ZagRepositoryIconPill())
			.accessibilityLabel("Share Repository")
			.disabled(_repositoryURLs.isEmpty)
		}
	}

	// Only show metadata we can actually verify from the loaded manifest.
	@Environment(\.colorScheme) private var _repositoryColorScheme

	private var _repositoryPillColor: Color {
		_repositoryColorScheme == .dark
			? Color(hex: "#1C1C1E")
			: Color(hex: "#EEEEEF")
	}

	private var _repositoryCardColor: Color {
		_repositoryColorScheme == .dark
			? Color(hex: "#111113")
			: Color(hex: "#F8F8FA")
	}

	// Curated statuses must be explicitly assigned; never infer trust from HTTPS or load success.
	// Add approved canonical manifest URLs here only after editorial review.
	private var _zagFeaturedManifestURLs: Set<String> {
		Set(SourcesAddView.zagFeaturedSourceURLs.map(\.absoluteString))
	}

	private var _isZagFeatured: Bool {
		guard let url = object.first?.sourceURL else { return false }
		return _zagFeaturedManifestURLs.contains(url.absoluteString)
	}

	private func _loadRepositoryManifestSize() {
		guard let url = object.first?.sourceURL,
			  ["https", "http"].contains(url.scheme?.lowercased() ?? "")
		else { return }

		_repositoryManifestBytes = nil
		let cacheRequest = URLRequest(url: url)
		if let cached = URLCache.shared.cachedResponse(for: cacheRequest),
		   !cached.data.isEmpty {
			_repositoryManifestBytes = Int64(cached.data.count)
			return
		}

		// Prefer metadata: avoids downloading large manifests a second time.
		var head = URLRequest(url: url)
		head.httpMethod = "HEAD"
		head.timeoutInterval = 10
		URLSession.shared.dataTask(with: head) { _, response, _ in
			if let http = response as? HTTPURLResponse,
			   (200..<300).contains(http.statusCode),
			   http.expectedContentLength > 0 {
				DispatchQueue.main.async {
					guard object.first?.sourceURL == url else { return }
					_repositoryManifestBytes = http.expectedContentLength
				}
				return
			}

			// Some repository hosts omit Content-Length or reject HEAD.
			// Fetch the actual manifest and count the bytes instead.
			var get = URLRequest(url: url)
			get.httpMethod = "GET"
			get.timeoutInterval = 45
			URLSession.shared.dataTask(with: get) { data, response, error in
				guard error == nil,
					  let http = response as? HTTPURLResponse,
					  (200..<300).contains(http.statusCode),
					  let data, !data.isEmpty else { return }
				let bytes = Int64(data.count)
				DispatchQueue.main.async {
					guard object.first?.sourceURL == url else { return }
					_repositoryManifestBytes = bytes
				}
			}.resume()
		}.resume()
	}

	// Local manifest health only: successfully parsed source with usable app entries.
	// This does not assert server uptime, IPA safety, or download-link validity.
	private var _repositoryIsHealthy: Bool {
		guard object.count == 1, let source = _sources?.first else { return false }
		return !(source.id ?? "").isEmpty && !source.apps.isEmpty
	}

	private var _repositorySummary: some View {
		VStack(alignment: .leading, spacing: 13) {
			HStack(spacing: 8) {
				if _isZagFeatured {
					ZagRepositoryFeaturedPill()
				}
				HStack(spacing: 6) {
					Image(systemName: _repositoryIsHealthy ? "heart.fill" : "questionmark.circle.fill")
						.foregroundStyle(_repositoryIsHealthy ? Color.green : Color.secondary)
					Text(_repositoryIsHealthy ? "Healthy" : "Unchecked")
						.foregroundStyle(.primary)
				}
				.padding(.horizontal, 11)
				.padding(.vertical, 8)
				.background(_repositoryPillColor, in: Capsule())

				if let bytes = _repositoryManifestBytes {
					HStack(spacing: 6) {
						Image(systemName: "doc.zipper")
						Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
					}
					.foregroundStyle(.secondary)
					.padding(.horizontal, 11)
					.padding(.vertical, 8)
					.background(_repositoryPillColor, in: Capsule())
				}
			}
			.font(.system(size: 12, weight: .semibold))

			if let url = object.first?.sourceURL {
				Divider()
				HStack(alignment: .center, spacing: 10) {
					Image(systemName: "link")
						.font(.system(size: 14, weight: .medium))
						.foregroundStyle(.secondary)
						.frame(width: 20)
					VStack(alignment: .leading, spacing: 4) {
						Text("SOURCE URL")
							.font(.system(size: 10, weight: .semibold))
							.tracking(0.7)
							.foregroundStyle(.tertiary)
						Text(url.absoluteString)
							.font(.system(size: 12, weight: .medium))
							.foregroundStyle(.secondary)
							.lineLimit(2)
							.textSelection(.enabled)
					}
					.frame(maxWidth: .infinity, alignment: .leading)
				}
			}
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 14)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(_repositoryCardColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
		.padding(.horizontal, ZagListLayout.horizontalInset)
	}

	private func _repositoryDetailRow(_ label: String, value: String) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 12) {
			Text(label)
				.foregroundStyle(.secondary)
			Spacer(minLength: 8)
			Text(value)
				.multilineTextAlignment(.trailing)
				.textSelection(.enabled)
		}
		.font(.subheadline)
	}


	private func _repositorySectionHeader(_ title: String, count: Int? = nil, collapsed: Bool, toggle: @escaping () -> Void) -> some View {
		Button(action: toggle) {
			HStack(spacing: 8) {
				if let count {
					ZagSectionHeader(title: title, count: count)
				} else {
					Text(title)
						.font(.system(size: 22, weight: .bold))
						.foregroundStyle(.primary)
				}
				Spacer(minLength: 8)
				Image(systemName: "chevron.down")
					.font(.system(size: 20, weight: .semibold))
					.foregroundStyle(.secondary)
					.frame(width: 44, height: 44)
					.rotationEffect(.degrees(collapsed ? -90 : 0))
					.animation(.easeInOut(duration: 0.28), value: collapsed)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityValue(collapsed ? "Collapsed" : "Expanded")
	}

	private var _repositoryDetailsLink: some View {
		Button { _showRepositoryDetails = true } label: {
			HStack(spacing: 12) {
				Image(systemName: "info.circle")
					.font(.system(size: 19, weight: .regular))
					.foregroundStyle(.tint)
					.frame(width: 24)
				Text("View Detailed Info")
					.foregroundStyle(.primary)
				Spacer(minLength: 8)
				Image(systemName: "chevron.right")
					.font(.system(size: 13, weight: .semibold))
					.foregroundStyle(.tertiary)
			}
			.font(.body)
			.padding(.horizontal, 16)
			.padding(.vertical, 13)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(_repositoryCardColor, in: RoundedRectangle(cornerRadius: 16))
			.padding(.horizontal, ZagListLayout.horizontalInset)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
	}

	private func _repositoryDetailsPage(_ source: ASRepository) -> some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 12) {
				_repositoryDetailRow("Repository", value: source.name ?? "Repository")
				Divider()
				if let identifier = source.id, !identifier.isEmpty {
					_repositoryDetailRow("Identifier", value: identifier)
					Divider()
				}
				_repositoryDetailRow("Total Apps", value: source.apps.count.formatted())
				Divider()
				_repositoryDetailRow("Manifest Status", value: _repositoryIsHealthy ? "Healthy (local validation)" : "Unchecked")
				Divider()
				_repositoryDetailRow("Zag Featured", value: _isZagFeatured ? "Yes" : "No")
				if let bytes = _repositoryManifestBytes {
					Divider()
					_repositoryDetailRow("Manifest Size", value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
				}
				if let url = object.first?.sourceURL {
					Divider()
					_repositoryDetailRow("Connection", value: url.scheme?.uppercased() ?? "Unknown")
					Divider()
					_repositoryDetailRow("Source URL", value: url.absoluteString)
					if let host = url.host {
						Divider()
						_repositoryDetailRow("Host", value: host)
					}
				}
				if let website = source.website {
					Divider()
					_repositoryDetailRow("Website", value: website.absoluteString)
				}
			}
			.padding(16)
			.background(_repositoryCardColor, in: RoundedRectangle(cornerRadius: 16))
			.padding(.horizontal, ZagListLayout.horizontalInset)
			.padding(.top, 16)
			.padding(.bottom, 32)
		}
		.zagWallpaperSurface()
		.navigationTitle("Repository Details")
		.navigationBarTitleDisplayMode(.large)
	}

	// MARK: Body
	var body: some View {
		NBListAdaptable(transparentBackground: true) {
			if let sources = _sources, !sources.isEmpty {
				if _searchText.isEmpty {
					Group {
						if object.count == 1 {
							Button {
								withAnimation(.easeInOut(duration: 0.28)) { _overviewCollapsed.toggle() }
							} label: {
								HStack(spacing: 6) {
									ZagRepositoryShield()
									Text(object[0].name ?? "Repository")
										.font(.system(size: 22, weight: .bold))
										.foregroundStyle(.primary)
										.lineLimit(1)
									Spacer(minLength: 8)
									Image(systemName: "chevron.down")
										.font(.system(size: 20, weight: .semibold))
										.foregroundStyle(.secondary)
										.frame(width: 44, height: 44)
										.rotationEffect(.degrees(_overviewCollapsed ? -90 : 0))
										.animation(.easeInOut(duration: 0.28), value: _overviewCollapsed)
								}
								.contentShape(Rectangle())
							}
							.buttonStyle(.plain)
							.accessibilityValue(_overviewCollapsed ? "Collapsed" : "Expanded")
						} else {
							ZagSectionHeader(title: "Your Sources", count: sources.reduce(0) { $0 + $1.apps.count })
						}
					}
					.listRowSeparator(.hidden)
					.listRowBackground(Color.clear)
					if object.count == 1 {
						if !_overviewCollapsed {
							_repositorySummary
								.listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 12, trailing: 0))
								.listRowSeparator(.hidden)
								.listRowBackground(Color.clear)
						}
						_repositorySectionHeader("Apps", count: sources.reduce(0) { $0 + $1.apps.count }, collapsed: _appsCollapsed) {
							withAnimation(.easeInOut(duration: 0.28)) { _appsCollapsed.toggle() }
						}
						.listRowSeparator(.hidden)
						.listRowBackground(Color.clear)
					}
				}
				if !_appsCollapsed || object.count != 1 || !_searchText.isEmpty {
					if _searchText.isEmpty, sources.count == 1, let news = sources.first?.news, !news.isEmpty {
						SourceNewsView(news: news)
							.listRowSeparator(.hidden)
							.listRowBackground(Color.clear)
					}
					ForEach(Array(repositoryEntries.enumerated()), id: \.element.id) { index, entry in
						SourceAppsCellView(source: entry.source, app: entry.app, showsRepositoryDetails: object.count == 1)
							.overlay(alignment: .bottom) {
								if index < repositoryEntries.count - 1 {
									Rectangle()
										.fill(Color(uiColor: .separator))
										.frame(height: ZagListLayout.separatorHeight)
								}
							}
							.listRowSeparator(.hidden)
							.listRowInsets(EdgeInsets(top: 0, leading: ZagListLayout.horizontalInset, bottom: 0, trailing: ZagListLayout.horizontalInset))
							.listRowBackground(Color.clear)
							.contentShape(Rectangle())
							.onTapGesture { _selectedRoute = entry }
							.transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .move(edge: .top))))
					}
				}
				if object.count == 1, _searchText.isEmpty, sources.first != nil {
					_repositorySectionHeader("Details", collapsed: _detailsCollapsed) {
						withAnimation(.easeInOut(duration: 0.28)) { _detailsCollapsed.toggle() }
					}
					.listRowSeparator(.hidden)
					.listRowBackground(Color.clear)
					if !_detailsCollapsed {
						_repositoryDetailsLink
							.listRowInsets(EdgeInsets())
							.listRowSeparator(.hidden)
							.listRowBackground(Color.clear)
					}
				}
				Color.clear.frame(height: 32)
					.listRowInsets(EdgeInsets())
					.listRowSeparator(.hidden)
					.listRowBackground(Color.clear)
			} else {
				ProgressView().frame(maxWidth: .infinity)
					.listRowBackground(Color.clear)
			}
		}
		.background {
			if object.count == 1 {
				ZagRepositoryScrollObserver(scrolled: $_repositoryScrolled)
					.frame(width: 0, height: 0)
			}
		}
		.zagWallpaperSurface()

		.overlay(alignment: .topTrailing) {
			if object.count == 1 && _searchText.isEmpty {
				_repositoryActionPills
					.padding(.trailing, ZagListLayout.horizontalInset)
					.offset(y: -96)
					.opacity(_repositoryScrolled ? 0 : 1)
					.allowsHitTesting(!_repositoryScrolled)
			}
		}
		.navigationDestination(isPresented: $_showRepositoryDetails) {
			if let source = _sources?.first { _repositoryDetailsPage(source) }
		}
		.navigationTitle(_navigationTitle)
		.navigationBarTitleDisplayMode(.large)
		.toolbarBackground(.hidden, for: .navigationBar)
		.toolbar {
			ToolbarItem(placement: .principal) {
				ZagLocalVPNToolbarStatus()
			}
		}
		.searchable(
			text: $_searchText,
			placement: .platform(),
			prompt: Text("Apps, Games in Repo")
		)
		.modifier(ZagRepositorySearchFocusModifier(isFocused: $_searchFieldFocused))
		.background {
			if object.count == 1 {
				ZagNativeSearchMicInstaller(
					isAvailable: _dictationAvailable,
					action: _startDictationFromSearchMic,
					prompt: "Apps, Games in Repo",
					activePrompt: "Apps, Games in Repo"
				)
				.frame(width: 0, height: 0)
			}
		}

		.modifier(ZagRepositoryActionsToolbar(sortActions: {
            Menu {
                _sortActions()
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
            }
        }))
		.onAppear {
			_loadRepositoryManifestSize()
			_probeSystemDictation()

			if !hasLoadedOnce, _requestedSourcesAreAvailable {
				_load()
				hasLoadedOnce = true
			}

			_sortOption = SortOption(rawValue: _sortOptionRawValue) ?? .default
		}
		.onChange(of: viewModel.isFinished) { _ in
			_load()
		}
		.onChange(of: viewModel.sources.count) { _ in
			if !hasLoadedOnce, _requestedSourcesAreAvailable {
				_load()
				hasLoadedOnce = true
			}
		}
		.onChange(of: _sortOption) { newValue in
			_sortOptionRawValue = newValue.rawValue
		}
		.background {
			NavigationLink(
				isActive: Binding(
					get: { _selectedRoute != nil },
					set: { isActive in
						if !isActive {
							_selectedRoute = nil
						}
					}
				)
			) {
				if let route = _selectedRoute {
					SourceAppsDetailView(
						source: route.source,
						app: route.app
					)
				} else {
					EmptyView()
				}
			} label: {
				EmptyView()
			}
			.frame(width: 0, height: 0)
			.opacity(0)
		}
	}

	private func _probeSystemDictation() {
		guard let cls = NSClassFromString("UIDictationController") as? NSObject.Type else {
			_dictationAvailable = false
			_dictationStatus = "UIDictationController unavailable"
			return
		}

		let sharedSelector = NSSelectorFromString("sharedInstance")
		guard cls.responds(to: sharedSelector),
			  let controller = cls.perform(sharedSelector)?.takeUnretainedValue() as? NSObject
		else {
			_dictationAvailable = false
			_dictationStatus = "System dictation controller unavailable"
			return
		}

		let startSelector = NSSelectorFromString("startDictation")
		_dictationAvailable = controller.responds(to: startSelector)
		_dictationStatus = _dictationAvailable
			? "Start Dictation"
			: "startDictation unavailable"
	}

	private func _startDictationFromSearchMic() {
		// The native searchable field must become first responder before
		// UIDictationController starts. Starting dictation while search is
		// resting leaves the system dictation session detached from the field.
		_searchFieldFocused = true

		DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
			_startSystemDictation()
		}
	}

	private func _startSystemDictation() {
		guard let cls = NSClassFromString("UIDictationController") as? NSObject.Type else {
			_probeSystemDictation()
			return
		}

		let sharedSelector = NSSelectorFromString("sharedInstance")
		guard cls.responds(to: sharedSelector),
			  let controller = cls.perform(sharedSelector)?.takeUnretainedValue() as? NSObject
		else {
			_probeSystemDictation()
			return
		}

		let preheatSelector = NSSelectorFromString("preheatIfNecessary")
		if controller.responds(to: preheatSelector) {
			_ = controller.perform(preheatSelector)
		}

		let startSelector = NSSelectorFromString("startDictation")
		guard controller.responds(to: startSelector) else {
			_probeSystemDictation()
			return
		}

		_ = controller.perform(startSelector)
	}
	
	private func _load() {
		isLoading = true
		
		Task {
			let loadedSources = object.compactMap { viewModel.sources[$0] }
			_sources = loadedSources
			withAnimation(.easeIn(duration: 0.2)) {
				isLoading = false
			}
		}
	}
	
	struct SourceAppRoute: Identifiable, Hashable, Sendable {
		let source: ASRepository
		let app: ASRepository.App

		// Keep repository/search rows stable across SwiftUI re-renders.
		// A random UUID here recreated DownloadButtonView whenever download,
		// signing, or Core Data state changed, interrupting its multi-stage
		// Get -> progress -> install -> Open animation sequence.
		var id: String {
			let sourceIdentity =
				source.id ??
				source.website?.absoluteString ??
				source.name ??
				"repository"
			return sourceIdentity + "|" + app.currentUniqueId
		}
	}
}

// MARK: - Extension: View (Sort)
extension SourceAppsView {
	@ViewBuilder
	private func _sortActions() -> some View {
		Section(.localized("Filter by")) {
			ForEach(SortOption.allCases, id: \.displayName) { opt in
				_sortButton(for: opt)
			}
		}
	}
	
	private func _sortButton(for option: SortOption) -> some View {
		Button {
			if _sortOption == option {
				_sortAscending.toggle()
			} else {
				_sortOption = option
				_sortAscending = true
			}
		} label: {
			HStack {
				Text(option.displayName)
				Spacer()
				if _sortOption == option {
					Image(systemName: _sortAscending ? "chevron.up" : "chevron.down")
				}
			}
		}
	}
}

import SwiftUI

extension View {
	@ViewBuilder
	func navigationDestinationIfAvailable<Item: Identifiable & Hashable, Destination: View>(
		item: Binding<Item?>,
		@ViewBuilder destination: @escaping (Item) -> Destination
	) -> some View {
		if #available(iOS 17, *) {
			self.navigationDestination(item: item, destination: destination)
		} else {
			self
		}
	}
}
