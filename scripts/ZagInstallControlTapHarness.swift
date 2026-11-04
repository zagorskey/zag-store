import SwiftUI

// Host app for the install-control tap UI tests. Each row mirrors how a
// real surface opens details around the shared control:
// - "gesture": row .onTapGesture (repository list, Library, App Updates)
// - "button":  row wrapped in a plain Button (repository search results)
// Every control tap and every row navigation is counted and exposed as the
// accessibility label of the "events" text, which the UI tests read.

final class TapEvents: ObservableObject {
	@Published var counts: [String: Int] = [:]
	/// Milliseconds between the last morph starting and the last tap on
	/// the morphing row (control action or row navigation).
	@Published var morphElapsed = -1
	var morphStart = Date.distantPast
	func record(_ key: String) {
		counts[key, default: 0] += 1
		if key.hasSuffix(":morphing") { morphElapsed = Int(Date().timeIntervalSince(morphStart) * 1000) }
	}
	var summary: String { counts.keys.sorted().map { "\($0)=\(counts[$0]!)" }.joined(separator: " ") }
}

private let tintC = Color(red: 0.247, green: 0.557, blue: 0.969)
private let fillC = Color(red: 0.933, green: 0.933, blue: 0.941)

private func pill(_ title: String, _ image: String? = nil) -> ZagInstallControlMode {
	.pill(ZagInstallPill(title: title, systemImage: image, accessibilityLabel: title))
}

private let compactResume = ZagInstallControlMode.pill(ZagInstallPill(title: "Resume", systemImage: "icloud.and.arrow.down", compactLabel: true, accessibilityLabel: "Resume"))

private struct Row: View {
	let name: String
	let mode: ZagInstallControlMode
	let parent: String
	@ObservedObject var events: TapEvents

	private var content: some View {
		HStack(spacing: 12) {
			RoundedRectangle(cornerRadius: 13).fill(Color.orange.opacity(0.8)).frame(width: 56, height: 56)
			Text(name)
				.font(.system(size: 15, weight: .semibold))
				.accessibilityIdentifier("title-\(name)")
			Spacer(minLength: 8)
			ZagInstallControlBody(mode: mode, tint: tintC, fill: fillC) { events.record("action:\(name)") }
				.accessibilityElement(children: .ignore)
				.accessibilityIdentifier("control-\(name)")
				.frame(width: 88, height: 70)
		}
		.padding(.horizontal, 20)
		.frame(height: 70)
		.contentShape(Rectangle())
	}

	var body: some View {
		if parent == "button" {
			Button { events.record("nav:\(name)") } label: { content }.buttonStyle(.plain)
		} else {
			content.onTapGesture { events.record("nav:\(name)") }
		}
	}
}

@main
struct ZagInstallControlTapHarness: App {
	@StateObject private var events = TapEvents()
	@State private var morphCompact = false

	var body: some Scene {
		WindowGroup {
			VStack(spacing: 0) {
				Text(events.summary.isEmpty ? "none" : events.summary)
					.font(.caption2)
					.accessibilityIdentifier("events")
					.frame(height: 24)
				Text("\(events.morphElapsed)")
					.font(.caption2)
					.accessibilityIdentifier("elapsed")
					.frame(height: 16)
				HStack {
					Button("reset") { events.counts = [:] }.accessibilityIdentifier("reset")
					Button("morph") { events.morphStart = Date(); morphCompact.toggle() }.accessibilityIdentifier("morph")
				}
				.frame(height: 40)
				Row(name: "get", mode: pill("Get"), parent: "gesture", events: events)
				Row(name: "update", mode: pill("Update"), parent: "button", events: events)
				Row(name: "ring", mode: .progress(0.4, .pause), parent: "gesture", events: events)
				Row(name: "spinner", mode: .spinner(.none), parent: "gesture", events: events)
				Row(name: "resume", mode: compactResume, parent: "gesture", events: events)
				Row(name: "open", mode: pill("Open"), parent: "button", events: events)
				Row(name: "morphing", mode: morphCompact ? .progress(0.4, .pause) : compactResume, parent: "gesture", events: events)
				Spacer()
			}
			.background(Color.white)
			.environment(\.colorScheme, .light)
		}
	}
}
