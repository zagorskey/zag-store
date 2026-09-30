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


// MARK: - Native Search Microphone

private struct ZagNativeSearchMicInstaller: UIViewRepresentable {
	let isAvailable: Bool
	let action: () -> Void

	func makeCoordinator() -> Coordinator {
		Coordinator(action: action)
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
		DispatchQueue.main.async {
			context.coordinator.install(from: uiView, isAvailable: isAvailable)
		}
	}

	final class Coordinator: NSObject {
		var action: () -> Void
		private weak var installedField: UISearchTextField?
		private weak var button: UIButton?

		init(action: @escaping () -> Void) {
			self.action = action
		}

		func install(from anchor: UIView, isAvailable: Bool) {
			guard let window = anchor.window else {
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
					self.install(from: anchor, isAvailable: isAvailable)
				}
				return
			}

			guard let field = Self.findSearchField(in: window) else { return }

			if installedField !== field || button == nil {
				let mic = UIButton(type: .system)
				mic.setImage(
					UIImage(
						systemName: "mic.fill",
						withConfiguration: UIImage.SymbolConfiguration(
							pointSize: 18,
							weight: .regular
						)
					),
					for: .normal
				)
				mic.tintColor = .placeholderText
				mic.frame = CGRect(x: 0, y: 0, width: 36, height: 36)
				mic.addTarget(self, action: #selector(micPressed), for: .touchUpInside)
				mic.accessibilityLabel = "Start Dictation"

				field.rightView = mic
				field.rightViewMode = .always
				installedField = field
				button = mic
			}

			button?.alpha = isAvailable ? 1.0 : 0.45
			button?.isEnabled = isAvailable
		}

		@objc private func micPressed() {
			action()
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

private struct ZagRepositorySearchFocusModifier: ViewModifier {
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
		.searchable(text: $_searchText, placement: .platform())
		.modifier(ZagRepositorySearchFocusModifier(isFocused: $_searchFieldFocused))
		.background {
			if object.count == 1 {
				ZagNativeSearchMicInstaller(
					isAvailable: _dictationAvailable,
					action: _startDictationFromSearchMic
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
