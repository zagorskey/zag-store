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
					.modifier(ZagMobileDataInstallOverlay())
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
			.onAppear { ZagInventorySnapshotRecorder.shared.start() }
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
		// Consumes only zagstore://shortcut-callback/…; all other links route as before.
		if ZagMobileDataToggleController.shared.handle(url) {
			return
		}
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
			/// feather://export-certificate is intentionally disabled.
			/// It sent the stored P12 and its password to a URL chosen by the
			/// caller, which any web page or app could supply. Certificates can
			/// still be exported deliberately from Settings → Certificates.
			if url.host == "export-certificate" {
				ZagLogger.shared.warning("DeepLink", "Ignored external certificate export request")
				return
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
    var isFinished: Bool { completed }
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilSplashFinishes() async {
        // No splash means no playback lifecycle to release the launch gate.
        // Unblock repository refresh even if the overlay never appears.
        if !ZagSplashPreferences.isEnabled {
            finish()
            return
        }
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
        NotificationCenter.default.post(
            name: .zagLaunchSplashVisibilityDidChange,
            object: nil,
            userInfo: ["visible": false]
        )
        // After the interface is interactive; returns at once (preview copies only).
        ZagFirstLaunchReporter.launchBecameInteractive()
    }
}

enum ZagSplashPreferences {
    static let enabledKey = "ZagStore.animatedSplashEnabled"
    static var isEnabled: Bool {
        // Opt-out: existing installations see the animation by default.
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }
}

/// The system launch frame is the exact first frame of the Kling master.
/// On normal cold starts, Zag Store
/// plays the ORIGINAL 5-second cinematic master (including its audio track).
/// A precise, native text reveal is layered above the unmodified video.
/// Reduced Motion and missing bundled video fall back to the existing
/// colour-preserving still/native Core Animation path.
private struct ZagAnimatedLaunchOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(ZagSplashPreferences.enabledKey) private var enabled = true
    @AppStorage("ZagStore.splashSoundEnabled") private var soundEnabled = true
    @State private var opacity: Double = 1
    @State private var exitRequested = false
    @State private var dismissed = false
    @State private var videoFadeStarted = false
    @State private var skipVideoRequested = false

    private var playsVideo: Bool {
        !reduceMotion && ZagCinematicSplashView.available
    }

    var body: some View {
        Group {
            // The launch gate is one-shot for the process lifetime. Changing
            // Settings must never recreate the video or restart its audio.
            if enabled && !dismissed && !ZagLaunchGate.shared.isFinished {
                Group {
                    if playsVideo {
                        ZagCinematicSplashView(
                            soundEnabled: soundEnabled,
                            skipRequested: skipVideoRequested,
                            onExitReady: beginVideoFade,
                            onFinished: finishVideo
                        )
                        // A transparent full-screen gesture surface: no Skip
                        // affordance competes with the original Z artwork.
                        .overlay {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { skipVideoRequested = true }
                                .accessibilityLabel("Skip introduction")
                                .accessibilityAddTraits(.isButton)
                        }
                    } else {
                        ZagSplashAnimationStage(
                            reduceMotion: reduceMotion,
                            exiting: exitRequested
                        )
                    }
                }
                .ignoresSafeArea()
                .opacity(opacity)
                .allowsHitTesting(true)
                // Keep the invisible Skip introduction button reachable to
                // VoiceOver; the video itself has no announced elements.
            }
        }
        .task {
            guard enabled else {
                complete()
                return
            }
            // Video completion comes from AVPlayerItemDidPlayToEndTime, not
            // an approximation that can drift with decode/startup latency.
            if playsVideo { return }

            if reduceMotion {
                try? await Task.sleep(for: .milliseconds(370))
            } else {
                try? await Task.sleep(
                    for: .milliseconds(Int64(
                        ZagSplashTimeline.heroHoldEnd * 1000
                    ))
                )
                guard !Task.isCancelled, !dismissed else { return }
                exitRequested = true
                let gap = ZagSplashTimeline.screenFadeStart
                    - ZagSplashTimeline.heroHoldEnd
                try? await Task.sleep(
                    for: .milliseconds(Int64(gap * 1000))
                )
            }

            guard !Task.isCancelled, !dismissed else { return }
            withAnimation(.easeInOut(
                duration: reduceMotion
                    ? 0.01 : ZagSplashTimeline.screenFadeDuration
            )) {
                opacity = 0
            }
            try? await Task.sleep(
                for: .milliseconds(Int64(
                    (reduceMotion ? 0.02 :
                        ZagSplashTimeline.finish
                            - ZagSplashTimeline.screenFadeStart) * 1000
                ))
            )
            guard !Task.isCancelled, !dismissed else { return }
            complete()
        }
        .onChange(of: enabled) { value in
            if !value { complete() }
        }
    }

    private func beginVideoFade() {
        guard !dismissed, !videoFadeStarted else { return }
        videoFadeStarted = true
        // The motto has already withdrawn. Now the unmodified video
        // dissolves into the real, fully-mounted Zag Store interface.
        withAnimation(.easeInOut(duration: 0.28)) {
            opacity = 0
        }
    }

    private func finishVideo() {
        guard !dismissed else { return }
        let wasFading = videoFadeStarted
        beginVideoFade()
        Task { @MainActor in
            // Normally the video finishes 0.28 s after the exit cue. If it
            // ends unexpectedly, let the same transition complete first.
            try? await Task.sleep(for: .milliseconds(
                wasFading ? 55 : 310
            ))
            complete()
        }
    }

    private func complete() {
        guard !dismissed else { return }
        dismissed = true
        ZagLaunchGate.shared.finish()
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

		// iOS requires exactly one completion, including when the task expires.
		// Without it the system reduces future background refresh time.
		let completion = ZagOnceCompletion { success in
			task.setTaskCompleted(success: success)
		}

		let work = Task {
			let success = await refreshRepositoriesAndUpdates()
			completion.complete(success: success && !Task.isCancelled)
		}

		task.expirationHandler = {
			work.cancel()
			if completion.complete(success: false) {
				Logger.misc.warning("[Zag Store Background] Update refresh expired before finishing")
			}
		}
	}

	func refreshNow() async -> Bool {
		await refreshRepositoriesAndUpdates()
	}

	private func refreshRepositoriesAndUpdates() async -> Bool {
		let snapshotStartedAt = Date()
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
			// Dropped if a foreground refresh started later and already
			// published: an older snapshot never replaces a newer one.
			UpdateManager.shared.refresh(
				repositories: completedRepositories,
				snapshotStartedAt: snapshotStartedAt
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
