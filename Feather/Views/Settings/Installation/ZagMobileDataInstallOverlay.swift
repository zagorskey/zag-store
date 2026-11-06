import SwiftUI

/// Root-level UI for Mobile Data Fix: the one-time consent, and recovery
/// when Zag Store can't confirm Mobile Data is back on. Progress is shown
/// on the app row, not here.
struct ZagMobileDataInstallOverlay: ViewModifier {
	@ObservedObject private var coordinator = ZagMobileDataInstallCoordinator.shared
	@Environment(\.scenePhase) private var scenePhase

	func body(content: Content) -> some View {
		content
			.overlay(alignment: .top) {
				VStack(spacing: 8) {
					if coordinator.recovery != nil, coordinator.stage == .idle {
						ZagMobileDataRecoveryBanner(coordinator: coordinator)
					}
				}
				.padding(.horizontal, 16)
				.padding(.top, 4)
				.animation(.smooth, value: coordinator.recovery)
			}
			.alert("Mobile Data Installation", isPresented: $coordinator.consentRequested) {
				Button("Allow Automatically") { coordinator.answerConsent(allow: true) }
				Button("Not Now", role: .cancel) { coordinator.answerConsent(allow: false) }
			} message: {
				Text(coordinator.consentOperation == .install
					? "Zag Store needs to temporarily turn off Mobile Data to install this app. It will restore your connection when installation finishes."
					: "Zag Store needs to temporarily turn off Mobile Data to remove this app. It will restore your connection when removal finishes.")
			}
			.onChange(of: scenePhase) { phase in
				if phase == .active { coordinator.refreshRecovery() }
			}
			.onAppear { coordinator.refreshRecovery() }
	}

}

private struct ZagMobileDataRecoveryBanner: View {
	@ObservedObject var coordinator: ZagMobileDataInstallCoordinator

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			Label {
				VStack(alignment: .leading, spacing: 2) {
					Text("Mobile Data may still be off")
						.font(.subheadline.weight(.semibold))
					Text(coordinator.recoveryMessage ?? "Turn it back on now, or tap Done if it's already on.")
						.font(.footnote)
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
				}
			} icon: {
				Image(systemName: "antenna.radiowaves.left.and.right.slash")
					.foregroundStyle(.orange)
			}
			HStack(spacing: 10) {
				Button {
					coordinator.restoreFromBanner()
				} label: {
					if coordinator.restoringFromBanner {
						ProgressView().controlSize(.small)
					} else {
						Text("Turn On Mobile Data")
					}
				}
				.buttonStyle(.borderedProminent)
				.disabled(coordinator.restoringFromBanner)

				Button("Done") { coordinator.dismissRecovery() }
					.buttonStyle(.bordered)
					.disabled(coordinator.restoringFromBanner)
			}
			.font(.subheadline.weight(.semibold))
		}
		.padding(16)
		.frame(maxWidth: 520, alignment: .leading)
		.zagMobileDataGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
		.transition(.move(edge: .top).combined(with: .opacity))
	}
}

private extension View {
	@ViewBuilder
	func zagMobileDataGlass<S: Shape>(in shape: S) -> some View {
		if #available(iOS 26.0, *) {
			self.glassEffect(.regular, in: shape)
		} else {
			self.background(.ultraThinMaterial, in: shape)
		}
	}
}
