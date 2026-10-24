//
//  FeatherApp.swift
//  Feather
//
//  Created by samara on 10.04.2025.
//

import SwiftUI
import Nuke
import IDeviceSwift
import OSLog
import BackgroundTasks
import CoreData
import AltSourceKit
import NimbleJSON

@main
struct FeatherApp: App {
	@UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
	
	let heartbeat = HeartbeatManager.shared
	
	@StateObject var downloadManager = DownloadManager.shared
	let storage = Storage.shared
	
	var body: some Scene {
		WindowGroup {
			ZStack {
				ZagWallpaperBackground()

				VariedTabbarView()
					.environment(\.managedObjectContext, storage.context)
					.onOpenURL(perform: _handleURL)
					.overlay(alignment: .top) {
						// Manual transfers float above the app rather than
						// resizing the tab/navigation hierarchy.
						DownloadHeaderView(downloadManager: downloadManager)
							.padding(.top, 4)
							.transition(.move(edge: .top).combined(with: .opacity))
						}
				ZagAnimatedLaunchOverlay()
			}
			.animation(.smooth, value: downloadManager.manualDownloads.description)
            .onAppear {
                NotificationCenter.default.post(
                    name: Notification.Name("ZagStore.importBannerVisibilityDidChange"),
                    object: nil,
                    userInfo: ["visible": !downloadManager.manualDownloads.isEmpty]
                )
            }
            .onChange(of: downloadManager.manualDownloads.isEmpty) { isEmpty in
                NotificationCenter.default.post(
                    name: Notification.Name("ZagStore.importBannerVisibilityDidChange"),
                    object: nil,
                    userInfo: ["visible": !isEmpty]
                )
            }
			.onReceive(NotificationCenter.default.publisher(for: .heartbeatInvalidHost)) { _ in
				DispatchQueue.main.async {
					UIAlertController.showAlertWithOk(
						title: "InvalidHostID",
						message: .localized("Your pairing file is invalid and is incompatible with your device, please import a valid pairing file.")
					)
				}
			}
			// dear god help me
			.onAppear {
				if let style = UIUserInterfaceStyle(rawValue: UserDefaults.standard.integer(forKey: "Feather.userInterfaceStyle")) {
					UIApplication.topViewController()?.view.window?.overrideUserInterfaceStyle = style
				}
				
				UIApplication.topViewController()?.view.window?.tintColor = UIColor(Color(hex: UserDefaults.standard.string(forKey: "Feather.userTintColor") ?? "#3F8EF7"))
			}
		}
	}
	
	private func _handleURL(_ url: URL) {
		if ZagStoreRouter.open(url) {
			return
		}
		if url.scheme == "feather" {
			/// feather://import-certificate?p12=<base64>&mobileprovision=<base64>&password=<base64>
			if url.host == "import-certificate" {
				guard
					let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
					let queryItems = components.queryItems
				else {
					return
				}
				
				func queryValue(_ name: String) -> String? {
					queryItems.first(where: { $0.name == name })?.value?.removingPercentEncoding
				}
				
				guard
					let p12Base64 = queryValue("p12"),
					let provisionBase64 = queryValue("mobileprovision"),
					let passwordBase64 = queryValue("password"),
					let passwordData = Data(base64Encoded: passwordBase64),
					let password = String(data: passwordData, encoding: .utf8)
				else {
					return
				}
				
				let generator = UINotificationFeedbackGenerator()
				generator.prepare()
				
				guard
					let p12URL = FileManager.default.decodeAndWrite(base64: p12Base64, pathComponent: ".p12"),
					let provisionURL = FileManager.default.decodeAndWrite(base64: provisionBase64, pathComponent: ".mobileprovision"),
					FR.checkPasswordForCertificate(for: p12URL, with: password, using: provisionURL)
				else {
					generator.notificationOccurred(.error)
					return
				}
				
				FR.handleCertificateFiles(
					p12URL: p12URL,
					provisionURL: provisionURL,
					p12Password: password
				) { error in
					if let error = error {
						UIAlertController.showAlertWithOk(title: .localized("Error"), message: error.localizedDescription)
					} else {
						generator.notificationOccurred(.success)
					}
				}
				
				return
			}
			/// feather://export-certificate?callback_template=<template>
			/// ?callback_template=: This is how we callback to the application requesting the certificate, this will be a url scheme
			/// 	example: livecontainer%3A%2F%2Fcertificate%3Fcert%3D%24%28BASE64_CERT%29%26password%3D%24%28PASSWORD%29
			/// 	decoded: livecontainer://certificate?cert=$(BASE64_CERT)&password=$(PASSWORD)
			/// $(BASE64_CERT) and $(PASSWORD) must be presenting in the callback template so we can replace them with the proper content
			if url.host == "export-certificate" {
				guard
					let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
				else {
					return
				}
				
				let queryItems = components.queryItems?.reduce(into: [String: String]()) { $0[$1.name.lowercased()] = $1.value } ?? [:]
				guard let callbackTemplate = queryItems["callback_template"]?.removingPercentEncoding else { return }
				
				FR.exportCertificateAndOpenUrl(using: callbackTemplate)
			}
			/// feather://source/<url>
			if let fullPath = url.validatedScheme(after: "/source/") {
				FR.handleSource(fullPath) { }
			}
			/// feather://install/<url.ipa>
			if
				let fullPath = url.validatedScheme(after: "/install/"),
				let downloadURL = URL(string: fullPath)
			{
				_ = DownloadManager.shared.startDownload(from: downloadURL)
			}
		} else {
			if url.pathExtension == "ipa" || url.pathExtension == "tipa" {
				if FileManager.default.isFileFromFileProvider(at: url) {
					guard url.startAccessingSecurityScopedResource() else { return }
					FR.handlePackageFile(url) { _ in }
				} else {
					FR.handlePackageFile(url) { _ in }
				}
				
				return
			}
		}
	}
}


@MainActor
final class ZagLaunchGate {
    static let shared = ZagLaunchGate()
    private var completed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilSplashFinishes() async {
        if completed { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func finish() {
        guard !completed else { return }
        ZagPerformanceMonitor.shared.markInteractive()
        completed = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private enum ZagSplashPreferences {
    static let enabledKey = "ZagStore.animatedSplashEnabled"
    static var isEnabled: Bool {
        // Opt-out: existing installations see the animation by default.
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }
}

/// Runs once per process, never when returning from the background.
///
/// The original 3D Zag Store image remains the only logo artwork. We reveal
/// its actual pixels along the Z's strokes; we never draw a replacement Z.
/// Starting with the complete artwork matches Launch Screen.storyboard exactly.
private struct ZagAnimatedLaunchOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(ZagSplashPreferences.enabledKey) private var enabled = true

    @State private var revealProgress: CGFloat = 0
    @State private var originalArtworkOpacity = 1.0
    @State private var overlayOpacity = 1.0
    @State private var dismissed = false

    var body: some View {
        Group {
            if !dismissed && enabled {
                GeometryReader { geometry in
                    ZStack {
                        Color.black

                        // The ambient cyan/magenta glow is derived from the
                        // EXISTING artwork. This is the backdrop while the
                        // sharply rendered 3D logo materializes.
                        splashArtwork(in: geometry.size)
                            .blur(radius: 55)
                            .opacity(0.74)

                        // Reveal the actual bevels, colours and reflections
                        // sequentially: upper stroke, diagonal, lower stroke.
                        // The path is only a MASK, never visible as artwork.
                        splashArtwork(in: geometry.size)
                            .mask {
                                ZagSplashArtworkReveal(progress: revealProgress)
                                    .fill(.white)
                                    .blur(radius: 1.2)
                            }

                        // Finish on the unmodified original image, preserving
                        // its full glow and pixel-perfect launch composition.
                        splashArtwork(in: geometry.size)
                            .opacity(originalArtworkOpacity)
                    }
                    .frame(
                        width: geometry.size.width,
                        height: geometry.size.height
                    )
                    .clipped()
                    .ignoresSafeArea()
                }
                .ignoresSafeArea()
                .opacity(overlayOpacity)
                .allowsHitTesting(true)
                .task {
                    if reduceMotion {
                        // No deconstruction or stroke motion when Reduce Motion
                        // is enabled; simply show the original 3D artwork.
                        try? await Task.sleep(for: .milliseconds(350))
                    } else {
                        // Match the static iOS launch screen for the first
                        // frame, then dissolve into its own ambient lighting.
                        try? await Task.sleep(for: .milliseconds(100))
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeOut(duration: 0.22)) {
                            originalArtworkOpacity = 0
                        }
                        try? await Task.sleep(for: .milliseconds(230))
                        guard !Task.isCancelled else { return }

                        // This is the visible animation: the original 3D Z
                        // forms along its real geometry, not a white shimmer.
                        withAnimation(.easeInOut(duration: 1.28)) {
                            revealProgress = 1
                        }
                        try? await Task.sleep(for: .milliseconds(1290))
                        guard !Task.isCancelled else { return }

                        // Resolve the mask into the full original artwork,
                        // including its outer light spill and background.
                        withAnimation(.easeOut(duration: 0.24)) {
                            originalArtworkOpacity = 1
                        }
                        try? await Task.sleep(for: .milliseconds(330))
                    }

                    guard !Task.isCancelled else { return }
                    withAnimation(
                        .easeInOut(duration: reduceMotion ? 0.01 : 0.34)
                    ) {
                        overlayOpacity = 0
                    }
                    try? await Task.sleep(
                        for: .milliseconds(reduceMotion ? 20 : 360)
                    )
                    guard !Task.isCancelled else { return }
                    complete()
                }
            }
        }
        .task {
            // Disabling the setting genuinely skips the splash and releases
            // the startup gate without a timer or animated overlay.
            if !ZagSplashPreferences.isEnabled {
                complete()
            }
        }
        .onChange(of: enabled) { value in
            if !value { complete() }
        }
    }

    private func splashArtwork(in size: CGSize) -> some View {
        Image("ZagSplashFull")
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: size.width, height: size.height)
            .clipped()
            .accessibilityHidden(true)
    }

    private func complete() {
        guard !dismissed else { return }
        dismissed = true
        ZagLaunchGate.shared.finish()
        NotificationCenter.default.post(
            name: .zagLaunchSplashVisibilityDidChange,
            object: nil,
            userInfo: ["visible": false]
        )
    }
}

/// Reveal-only geometry, calibrated to ZagSplashFull.png (863 x 1822).
///
/// The Z remains a bitmap with its original 3D lighting and texture. This
/// stroked path is exclusively a progressively uncovered alpha mask.
/// Coordinates are mapped through the same aspect-fill transform as the image,
/// so the mask stays aligned on different iPhone screen sizes.
private struct ZagSplashArtworkReveal: Shape {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let artworkWidth: CGFloat = 863
        let artworkHeight: CGFloat = 1822
        let scale = max(
            rect.width / artworkWidth,
            rect.height / artworkHeight
        )
        let offsetX = (rect.width - artworkWidth * scale) * 0.5
        let offsetY = (rect.height - artworkHeight * scale) * 0.5

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: offsetX + x * scale, y: offsetY + y * scale)
        }

        var centerline = Path()
        centerline.move(to: point(249, 711))
        centerline.addLine(to: point(615, 711))
        centerline.addLine(to: point(249, 1084))
        centerline.addLine(to: point(615, 1084))

        return centerline
            .trimmedPath(from: 0, to: min(max(progress, 0), 1))
            .strokedPath(
                StrokeStyle(
                    lineWidth: 145 * scale,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
	func application(
		_ application: UIApplication,
		didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
	) -> Bool {
		// This is the earliest stable app-delegate milestone. Store the
		// monotonic timestamp only if diagnostics were enabled previously.
		if UserDefaults.standard.bool(forKey: ZagPerformanceSettings.enabledKey) {
			let launchStarted = ProcessInfo.processInfo.systemUptime
			Task { @MainActor in
				ZagPerformanceMonitor.shared.markLaunchStarted(at: launchStarted)
			}
		}
		_createPipeline()
		_createDocumentsDirectories()
		ResetView.clearWorkCache()
		_addDefaultCertificates()
		ZagBackgroundUpdateRefresh.shared.register()
		ZagBackgroundUpdateRefresh.shared.applySchedulingPreference()
		application.isIdleTimerDisabled = UserDefaults.standard.bool(
			forKey: "ZagStore.disableIdleTimeout"
		)
		return true
	}
	
	private func _createPipeline() {
		DataLoader.sharedUrlCache.diskCapacity = 0
		
		let pipeline = ImagePipeline {
			let dataLoader: DataLoader = {
				let config = URLSessionConfiguration.default
				config.urlCache = nil
				return DataLoader(configuration: config)
			}()
			let dataCache = try? DataCache(name: "thewonderofyou.Feather.datacache") // disk cache
			let imageCache = Nuke.ImageCache() // memory cache
			dataCache?.sizeLimit = 500 * 1024 * 1024
			imageCache.costLimit = 100 * 1024 * 1024
			$0.dataCache = dataCache
			$0.imageCache = imageCache
			$0.dataLoader = dataLoader
			$0.dataCachePolicy = .automatic
			$0.isStoringPreviewsInMemoryCache = false
		}
		
		ImagePipeline.shared = pipeline
	}
	
	private func _createDocumentsDirectories() {
		let fileManager = FileManager.default

		let directories: [URL] = [
			fileManager.archives,
			fileManager.certificates,
			fileManager.signed,
			fileManager.unsigned
		]
		
		for url in directories {
			try? fileManager.createDirectoryIfNeeded(at: url)
		}
	}
	
	private func _addDefaultCertificates() {
		guard
			UserDefaults.standard.bool(forKey: "feather.didImportDefaultCertificates") == false,
			let signingAssetsURL = Bundle.main.url(forResource: "signing-assets", withExtension: nil)
		else {
			return
		}
		
		do {
			let folderContents = try FileManager.default.contentsOfDirectory(
				at: signingAssetsURL,
				includingPropertiesForKeys: nil,
				options: .skipsHiddenFiles
			)
			
			for folderURL in folderContents {
				guard folderURL.hasDirectoryPath else { continue }
				
				let certName = folderURL.lastPathComponent
				
				let p12Url = folderURL.appendingPathComponent("cert.p12")
				let provisionUrl = folderURL.appendingPathComponent("cert.mobileprovision")
				let passwordUrl = folderURL.appendingPathComponent("cert.txt")
				
				guard
					FileManager.default.fileExists(atPath: p12Url.path),
					FileManager.default.fileExists(atPath: provisionUrl.path),
					FileManager.default.fileExists(atPath: passwordUrl.path)
				else {
					Logger.misc.warning("Skipping \(certName): missing required files")
					continue
				}
				
				let password = try String(contentsOf: passwordUrl, encoding: .utf8)
				
				FR.handleCertificateFiles(
					p12URL: p12Url,
					provisionURL: provisionUrl,
					p12Password: password,
					certificateName: certName,
					isDefault: true
				) { _ in
					
				}
			}
			UserDefaults.standard.set(true, forKey: "feather.didImportDefaultCertificates")
		} catch {
			Logger.misc.error("Failed to list signing-assets: \(error)")
		}
	}

	
	func applicationDidEnterBackground(_ application: UIApplication) {
		ZagBackgroundUpdateRefresh.shared.applySchedulingPreference()
		if ZagRPPairingCore.shared.isRunning {
			ZagRPPairingCore.shared.refreshPairingBackgroundTime()
		}
	}

	func applicationDidBecomeActive(_ application: UIApplication) {
		if ZagRPPairingCore.shared.isRunning {
			ZagRPPairingCore.shared.refreshPairingBackgroundTime()
		}
	}

}


// MARK: - Zag Store Background Update Refresh

final class ZagBackgroundUpdateRefresh {
	static let shared = ZagBackgroundUpdateRefresh()

	private let taskIdentifier = "com.cwd43.gu29.background-update-check"
	private let refreshInterval: TimeInterval = 60 * 60 * 4
	private let dataService = NBFetchService()
	static let enabledKey = "ZagStore.backgroundUpdatesEnabled"
	static let automaticPreparationKey = "ZagStore.automaticUpdatePreparation"
	static let automaticInstallationKey = "ZagStore.automaticUpdateInstallation"

	private init() {}

	func register() {
		BGTaskScheduler.shared.register(
			forTaskWithIdentifier: taskIdentifier,
			using: nil
		) { task in
			guard let refreshTask = task as? BGAppRefreshTask else {
				task.setTaskCompleted(success: false)
				return
			}
			self.handle(refreshTask)
		}
	}

	func applySchedulingPreference() {
		if UserDefaults.standard.bool(forKey: Self.enabledKey) {
			schedule()
		} else {
			cancel()
		}
	}

	func cancel() {
		BGTaskScheduler.shared.cancel(
			taskRequestWithIdentifier: taskIdentifier
		)
		Logger.misc.info("[Zag Store Background] Background updates disabled")
	}

	func schedule() {
		guard UserDefaults.standard.bool(forKey: Self.enabledKey) else {
			cancel()
			return
		}

		BGTaskScheduler.shared.cancel(
			taskRequestWithIdentifier: taskIdentifier
		)

		let request = BGAppRefreshTaskRequest(
			identifier: taskIdentifier
		)
		request.earliestBeginDate = Date(
			timeIntervalSinceNow: refreshInterval
		)

		do {
			try BGTaskScheduler.shared.submit(request)
			Logger.misc.info(
				"[Zag Store Background] Update refresh scheduled"
			)
		} catch {
			Logger.misc.error(
				"[Zag Store Background] Schedule failed: \(error.localizedDescription)"
			)
		}
	}

	private func handle(_ task: BGAppRefreshTask) {
		// Every execution schedules the next opportunity before doing network
		// work, so an expiration or termination does not break the chain.
		schedule()

		let work = Task {
			let success = await refreshRepositoriesAndUpdates()
			guard !Task.isCancelled else { return }
			task.setTaskCompleted(success: success)
		}

		task.expirationHandler = {
			work.cancel()
		}
	}

	func refreshNow() async -> Bool {
		await refreshRepositoriesAndUpdates()
	}

	private func refreshRepositoriesAndUpdates() async -> Bool {
		let sources = Storage.shared.getSources()
		guard !sources.isEmpty else {
			await MainActor.run {
				UpdateManager.shared.refresh(repositories: [])
			}
			return true
		}

		var repositories: [ASRepository] = []

		await withTaskGroup(of: ASRepository?.self) { group in
			for source in sources {
				guard let url = source.sourceURL else { continue }

				group.addTask {
					await withCheckedContinuation { continuation in
						self.dataService.fetch(from: url) {
							(result: Result<ASRepository, Error>) in
							switch result {
							case .success(let repository):
								continuation.resume(returning: repository)
							case .failure:
								continuation.resume(returning: nil)
							}
						}
					}
				}
			}

			for await repository in group {
				if let repository {
					repositories.append(repository)
				}
			}
		}

		guard !Task.isCancelled else { return false }

		// Never publish a partial repository snapshot. A transient source
		// failure would otherwise make valid updates disappear until the next
		// successful refresh. The last complete snapshot remains authoritative.
		guard repositories.count == sources.count else {
			Logger.misc.warning(
				"[Zag Store Background] Incomplete refresh: \(repositories.count)/\(sources.count) repositories. Keeping previous update state."
			)
			return false
		}

		let completedRepositories = repositories

		await MainActor.run {
			UpdateManager.shared.refresh(
				repositories: completedRepositories
			)
		}

		guard !Task.isCancelled else { return false }

		if UserDefaults.standard.bool(forKey: Self.automaticPreparationKey) {
			let updates = await MainActor.run { UpdateManager.shared.updates }
			for update in updates {
				guard !Task.isCancelled else { return false }
				do {
					let signedUUID = try await ZagUpdateTransactionManager.shared.prepareAsync(update)
					Logger.misc.info("[Zag Store Background] Prepared update for \(update.app.currentName)")

					if UserDefaults.standard.bool(forKey: Self.automaticInstallationKey) {
						guard #available(iOS 17.0, *) else {
							Logger.misc.warning("[Zag Store Background] Automatic installation requires iOS 17 or later")
							continue
						}
						try await ZagUpdateTransactionManager.shared.installPreparedUpdate(signedUUID: signedUUID)
						Logger.misc.info("[Zag Store Background] Installed update for \(update.app.currentName)")
					}
				} catch {
					Logger.misc.error("[Zag Store Background] Automatic update failed for \(update.app.currentName): \(error.localizedDescription)")
				}
			}
		}

		Logger.misc.info(
			"[Zag Store Background] Refreshed \(repositories.count) repositories"
		)
		return true
	}
}
