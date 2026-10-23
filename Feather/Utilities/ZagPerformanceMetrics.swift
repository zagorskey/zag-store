//
//  ZagPerformanceMetrics.swift
//  Feather
//
//  Opt-in, local-only performance samples. No app names, repository URLs,
//  identities, or device identifiers are collected or transmitted.
//

import Foundation
import Combine
import SwiftUI
import UIKit

enum ZagPerformanceSettings {
    static let enabledKey = "ZagStore.performanceMetricsEnabled"
    static let samplesKey = "ZagStore.performanceMetrics.v1"
}

enum ZagPerformanceCategory: String, CaseIterable, Codable, Sendable {
    case launchInteractive
    case launchSources
    case promotionalArtwork
    case catalogueLookup
    case featuredArtwork
    case galleryFirst
    case galleryComplete
    case previewFullResolution
    case galleryScroll

    var title: String {
        switch self {
        case .launchInteractive: return "Launch → Interactive"
        case .launchSources: return "Launch → Sources"
        case .promotionalArtwork: return "Promotional Artwork"
        case .catalogueLookup: return "Apple Catalogue"
        case .featuredArtwork: return "Featured Artwork"
        case .galleryFirst: return "First 3 Screenshots"
        case .galleryComplete: return "Screenshot Gallery"
        case .previewFullResolution: return "Full-Resolution Preview"
        case .galleryScroll: return "Screenshot Scrolling"
        }
    }
}

struct ZagPerformanceSample: Identifiable, Codable, Sendable {
    let id: UUID
    let date: Date
    let category: ZagPerformanceCategory
    let milliseconds: Double
    let result: String
    let longFrameGaps: Int?

    init(
        category: ZagPerformanceCategory,
        milliseconds: Double,
        result: String = "",
        longFrameGaps: Int? = nil
    ) {
        self.id = UUID()
        self.date = Date()
        self.category = category
        self.milliseconds = milliseconds
        self.result = result
        self.longFrameGaps = longFrameGaps
    }
}

@MainActor
final class ZagPerformanceMonitor: ObservableObject {
    static let shared = ZagPerformanceMonitor()

    @Published private(set) var samples: [ZagPerformanceSample] = []

    // Disk writes do not run on the main/UI thread.
    private let persistenceQueue = DispatchQueue(
        label: "ZagStore.PerformanceMetricsStorage",
        qos: .utility
    )
    private var launchUptime: TimeInterval?
    private var didRecordInteractive = false
    private var didRecordSources = false

    private init() {
        if let stored = UserDefaults.standard.data(forKey: ZagPerformanceSettings.samplesKey),
           let restored = try? JSONDecoder().decode([ZagPerformanceSample].self, from: stored) {
            samples = Array(restored.prefix(120))
        }
    }

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: ZagPerformanceSettings.enabledKey)
    }

    static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    func markLaunchStarted(at time: TimeInterval) {
        guard isEnabled, launchUptime == nil else { return }
        launchUptime = time
    }

    func markInteractive() {
        guard !didRecordInteractive, let launchUptime else { return }
        didRecordInteractive = true
        record(.launchInteractive, since: launchUptime)
    }

    func markSourcesCompleted() {
        guard !didRecordSources, let launchUptime else { return }
        didRecordSources = true
        record(.launchSources, since: launchUptime)
    }

    func record(
        _ category: ZagPerformanceCategory,
        since start: TimeInterval,
        result: String = "",
        longFrameGaps: Int? = nil
    ) {
        guard isEnabled else { return }
        let duration = max(0, (Self.now() - start) * 1000)
        guard duration.isFinite, duration < 600_000 else { return }
        let sample = ZagPerformanceSample(
            category: category,
            milliseconds: duration,
            result: result,
            longFrameGaps: longFrameGaps
        )
        samples.insert(sample, at: 0)
        if samples.count > 120 {
            samples.removeLast(samples.count - 120)
        }
        persist()
    }

    func clear() {
        samples.removeAll()
        // Serializes clear after any previously enqueued writes.
        persist()
    }

    private func persist() {
        let snapshot = samples
        persistenceQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            UserDefaults.standard.set(data, forKey: ZagPerformanceSettings.samplesKey)
        }
    }

    func report() -> String {
        var lines = [
            "Zag Store Performance Diagnostics",
            "Local-only measurements. Durations are in milliseconds.",
            "Samples: \(samples.count)",
            ""
        ]
        for category in ZagPerformanceCategory.allCases {
            let values = samples.filter { $0.category == category }
                .map(\.milliseconds).sorted()
            guard !values.isEmpty else { continue }
            let median = values[values.count / 2]
            let p95Index = min(values.count - 1, Int(ceil(Double(values.count) * 0.95)) - 1)
            let p95 = values[p95Index]
            lines.append("\(category.title): n=\(values.count), median=\(Int(median))ms, p95=\(Int(p95))ms")
        }
        lines.append("")
        for sample in samples {
            let gapText = sample.longFrameGaps.map { ", >50ms gaps=\($0)" } ?? ""
            lines.append("\(sample.date.formatted(date: .numeric, time: .standard)) | \(sample.category.title) | \(Int(sample.milliseconds))ms | \(sample.result)\(gapText)")
        }
        return lines.joined(separator: "\n")
    }
}

// Only samples while the gallery is scrolling. This is a frame-gap proxy,
// NOT a precise FPS or compositor dropped-frame count.
@MainActor
final class ZagGalleryScrollFrameSampler: NSObject, ObservableObject {
    private var displayLink: CADisplayLink?
    private var startUptime: TimeInterval = 0
    private var previousTimestamp: CFTimeInterval?
    private var longFrameGaps = 0

    func start() {
        guard ZagPerformanceMonitor.shared.isEnabled, displayLink == nil else { return }
        startUptime = ZagPerformanceMonitor.now()
        previousTimestamp = nil
        longFrameGaps = 0
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        if let previousTimestamp,
           link.timestamp - previousTimestamp > 0.050 {
            longFrameGaps += 1
        }
        previousTimestamp = link.timestamp
    }

    func stop() {
        guard let link = displayLink else { return }
        link.invalidate()
        displayLink = nil
        guard ZagPerformanceMonitor.now() - startUptime > 0.15 else { return }
        ZagPerformanceMonitor.shared.record(
            .galleryScroll,
            since: startUptime,
            result: "scroll interval",
            longFrameGaps: longFrameGaps
        )
    }
}

struct ZagGalleryScrollMetricsModifier: ViewModifier {
    @StateObject private var sampler = ZagGalleryScrollFrameSampler()

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .onScrollPhaseChange { _, phase in
                    if phase.isScrolling {
                        sampler.start()
                    } else {
                        sampler.stop()
                    }
                }
                .onDisappear { sampler.stop() }
        } else {
            content
        }
    }
}
