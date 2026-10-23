//
//  ZagPerformanceDiagnosticsView.swift
//  Feather
//
//  Simple on-device measurements with no telemetry or remote upload.
//

import SwiftUI
import UIKit

struct ZagPerformanceDiagnosticsView: View {
    @ObservedObject private var monitor = ZagPerformanceMonitor.shared
    @AppStorage(ZagPerformanceSettings.enabledKey) private var enabled = false

    var body: some View {
        Form {
            Section {
                Toggle("Measure Performance", isOn: $enabled)
                    .tint(.accentColor)
            } header: {
                Text("Collection")
            } footer: {
                Text("Off by default. Measurements are stored only on this device. To capture cold launch, enable this option, then fully close and reopen Zag Store. No app names, URLs or device identifiers are collected.")
            }

            Section {
                if monitor.samples.isEmpty {
                    Text("No measurements recorded yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(ZagPerformanceCategory.allCases, id: \.self) { category in
                        let values = monitor.samples
                            .filter { $0.category == category }
                            .map(\.milliseconds)
                            .sorted()
                        if !values.isEmpty {
                            _summaryRow(category: category, values: values)
                        }
                    }
                }
            } header: {
                Text("Loading Times")
            } footer: {
                Text("Median and p95 from recent measurements. Scroll rows show scroll duration; frame gaps longer than 50ms are a rough smoothness indicator, not a precise dropped-frame count.")
            }

            if !monitor.samples.isEmpty {
                Section {
                    ForEach(Array(monitor.samples.prefix(40))) { sample in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(sample.category.title)
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Text("\(Int(sample.milliseconds.rounded())) ms")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }

                            HStack {
                                Text(sample.date.formatted(date: .abbreviated, time: .standard))
                                if !sample.result.isEmpty {
                                    Text("· " + sample.result)
                                }
                                if let gaps = sample.longFrameGaps {
                                    Text("· >50ms gaps: \(gaps)")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Recent Samples")
                }
            }

            Section {
                Button {
                    UIPasteboard.general.string = monitor.report()
                } label: {
                    Label("Copy Performance Report", systemImage: "doc.on.doc")
                }
                .disabled(monitor.samples.isEmpty)

                Button(role: .destructive) {
                    monitor.clear()
                } label: {
                    Label("Clear Measurements", systemImage: "trash")
                }
                .disabled(monitor.samples.isEmpty)
            } footer: {
                Text("Copying the report places text on your clipboard; Zag Store does not send it anywhere. Older samples are automatically discarded after 120 measurements.")
            }
        }
        .navigationTitle("Performance")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func _summaryRow(
        category: ZagPerformanceCategory,
        values: [Double]
    ) -> some View {
        let median = values[values.count / 2]
        let p95Index = max(0, min(values.count - 1, Int(ceil(Double(values.count) * 0.95)) - 1))
        let p95 = values[p95Index]

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(category.title)
                    .font(.subheadline)
                Text("\(values.count) samples")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(Int(median.rounded())) ms")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                Text("p95 \(Int(p95.rounded())) ms")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
