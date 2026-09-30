import SwiftUI
import UIKit

enum ZagWallpaperStore {
	static let enabledKey = "zagStore.wallpaper.enabled"
	static let blurKey = "zagStore.wallpaper.blur"

	static var url: URL {
		let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
		return base.appendingPathComponent("ZagStore", isDirectory: true)
			.appendingPathComponent("wallpaper.jpg")
	}

	static func save(_ image: UIImage) throws {
		let directory = url.deletingLastPathComponent()
		try FileManager.default.createDirectory(
			at: directory,
			withIntermediateDirectories: true
		)
		guard let data = image.jpegData(compressionQuality: 0.92) else {
			throw CocoaError(.fileWriteUnknown)
		}
		try data.write(to: url, options: .atomic)
		UserDefaults.standard.set(true, forKey: enabledKey)
		NotificationCenter.default.post(name: .zagWallpaperChanged, object: nil)
	}

	static func clear() {
		try? FileManager.default.removeItem(at: url)
		UserDefaults.standard.set(false, forKey: enabledKey)
		NotificationCenter.default.post(name: .zagWallpaperChanged, object: nil)
	}

	static func image() -> UIImage? {
		guard let data = try? Data(contentsOf: url) else { return nil }
		return UIImage(data: data)
	}
}

extension Notification.Name {
	static let zagWallpaperChanged = Notification.Name("ZagStore.wallpaperChanged")
}

struct ZagWallpaperBackground: View {
	@AppStorage(ZagWallpaperStore.enabledKey) private var enabled = false
	@AppStorage(ZagWallpaperStore.blurKey) private var blurred = false
	@State private var image: UIImage?

	var body: some View {
		GeometryReader { proxy in
			if enabled, let image {
				Image(uiImage: image)
					.resizable()
					.scaledToFill()
					.frame(width: proxy.size.width, height: proxy.size.height)
					.clipped()
					.blur(radius: blurred ? 16 : 0)
					.scaleEffect(blurred ? 1.08 : 1)
			}
		}
		.ignoresSafeArea()
		.allowsHitTesting(false)
		.onAppear(perform: reload)
		.onReceive(NotificationCenter.default.publisher(for: .zagWallpaperChanged)) { _ in
			reload()
		}
	}

	private func reload() {
		image = ZagWallpaperStore.image()
	}
}

struct ZagWallpaperPicker: UIViewControllerRepresentable {
	let onPick: (UIImage) -> Void
	@Environment(\.dismiss) private var dismiss

	func makeUIViewController(context: Context) -> UIImagePickerController {
		let picker = UIImagePickerController()
		picker.sourceType = .photoLibrary
		picker.delegate = context.coordinator
		return picker
	}

	func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

	func makeCoordinator() -> Coordinator {
		Coordinator(parent: self)
	}

	final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
		let parent: ZagWallpaperPicker

		init(parent: ZagWallpaperPicker) {
			self.parent = parent
		}

		func imagePickerController(
			_ picker: UIImagePickerController,
			didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
		) {
			if let image = info[.originalImage] as? UIImage {
				parent.onPick(image)
			}
			picker.dismiss(animated: true)
		}

		func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
			picker.dismiss(animated: true)
		}
	}
}


private struct ZagWallpaperListBackgroundModifier: ViewModifier {
	@AppStorage(ZagWallpaperStore.enabledKey) private var enabled = false

	@ViewBuilder
	func body(content: Content) -> some View {
		if enabled {
			content
				.scrollContentBackground(.hidden)
				.background(Color.clear)
		} else {
			content
		}
	}
}

extension View {
	func zagWallpaperListBackground() -> some View {
		modifier(ZagWallpaperListBackgroundModifier())
	}

	/// Places the wallpaper immediately behind the page's own scroll surface.
	/// This deliberately avoids relying on transparency through TabView /
	/// NavigationStack, whose system backgrounds can otherwise hide the root wallpaper.
	func zagWallpaperSurface() -> some View {
		self
			.zagWallpaperListBackground()
			.background {
				ZagWallpaperBackground()
			}
	}
}
