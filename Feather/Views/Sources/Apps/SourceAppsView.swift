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
			yieldingToNativeClearButton = true
			field.removeTarget(self, action: #selector(searchTextChanged), for: .editingChanged)
			field.addTarget(self, action: #selector(searchTextChanged), for: .editingChanged)

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
			applyPlaceholderStyle(to: field, focused: true)
		}

		@objc private func searchFocusEnded(_ field: UISearchTextField) {
			applyPlaceholderStyle(to: field, focused: false)
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
	@State private var _dictationAvailable = false
	@State private var _dictationStatus = "Dictation unavailable"
	@FocusState private var _searchFieldFocused: Bool

	private var _navigationTitle: String {
		if object.count == 1 {
			object[0].name ?? .localized("Unknown")
		} else {
			.localized("%lld Sources", arguments: object.count)
		}
	}
	
	var object: [AltSource]
	@ObservedObject var viewModel: SourcesViewModel
	@State private var _sources: [ASRepository]?
	
	// MARK: Body
	var body: some View {
		ZStack {
			if
				let _sources,
				!_sources.isEmpty
			{
				SourceAppsTableRepresentableView(
					sources: _sources,
					searchText: $_searchText,
					sortOption: $_sortOption,
					sortAscending: $_sortAscending,
					onSelect: {self._selectedRoute = $0}
				)
				.ignoresSafeArea()
			} else {
				ProgressView()
			}
		}
		.navigationTitle(_navigationTitle)
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
		.toolbarTitleMenu {
			if
				let _sources,
				_sources.count == 1
			{
				if let url = _sources[0].website {
					Button(.localized("Visit Website"), systemImage: "globe") {
						UIApplication.open(url)
					}
				}
				
				if let url = _sources[0].patreonURL {
					Button(.localized("Visit Patreon"), systemImage: "dollarsign.circle") {
						UIApplication.open(url)
					}
				}
			}
			
			Divider()
			
			Button(.localized("Copy"), systemImage: "doc.on.doc") {
				guard !object.isEmpty else {
					UIAlertController.showAlertWithOk(
						title: .localized("Error"),
						message: .localized("No sources to copy")
					)
					return
				}
				UIPasteboard.general.string = object.map {
					$0.sourceURL!.absoluteString
				}.joined(separator: "\n")
				UIAlertController.showAlertWithOk(
					title: .localized("Success"),
					message: .localized("Sources copied to clipboard")
				)
			}
		}
		.toolbar {
			NBToolbarMenu(
				systemImage: "line.3.horizontal.decrease",
				style: .icon,
				placement: .topBarTrailing
			) {
				_sortActions()
			}
		}
		.onAppear {
			_probeSystemDictation()
			if !hasLoadedOnce, viewModel.isFinished {
				_load()
				hasLoadedOnce = true
			}
			_sortOption = SortOption(rawValue: _sortOptionRawValue) ?? .default
		}
		.onChange(of: viewModel.isFinished) { _ in
			_load()
		}
		.onChange(of: _sortOption) { newValue in
			_sortOptionRawValue = newValue.rawValue
		}
		.navigationDestinationIfAvailable(item: $_selectedRoute) { route in
			SourceAppsDetailView(source: route.source, app: route.app)
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
	
	struct SourceAppRoute: Identifiable, Hashable {
		let source: ASRepository
		let app: ASRepository.App
		let id: String = UUID().uuidString
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
