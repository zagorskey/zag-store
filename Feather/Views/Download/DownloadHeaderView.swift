//
//  DownloadHeaderView.swift
//  Feather
//
//  Created by samara on 16.05.2025.
//

import SwiftUI
import Combine
import NimbleExtensions

struct DownloadHeaderView: View {
	@ObservedObject var downloadManager: DownloadManager
	
	var body: some View {
		ZStack {
			if !downloadManager.manualDownloads.isEmpty {
				VStack {
					VStack(spacing: 12) {
						if let firstDownload = downloadManager.manualDownloads.first {
							DownloadItemView(download: firstDownload)
							
							if downloadManager.manualDownloads.count > 1 {
								HStack {
									Spacer()
									Text(verbatim: "+\(downloadManager.manualDownloads.count - 1)")
										.font(.caption)
										.foregroundColor(.secondary)
										.padding(.vertical, 4)
								}
							}
						}
					}
					.padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                    }
                    .padding(.horizontal, 14)
				}
				.transition(.move(edge: .top).combined(with: .opacity))
			}
		}
		.animation(.spring(), value: downloadManager.manualDownloads.count)
	}
}

struct DownloadItemView: View {
	let download: Download
	@State private var progress: Double = 0
	@State private var bytesDownloaded: Int64 = 0
	@State private var totalBytes: Int64 = 0
	@State private var unpackageProgress: Double = 0
	
	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(download.fileName)
				.font(.subheadline)
				.lineLimit(1)
			
            ZagImportGradientProgress(progress: overallProgress)
                .frame(height: 5)
			
			HStack {
				Text(verbatim: "\(Int(overallProgress * 100))%")
					.contentTransition(.numericText())
				Spacer()
				if totalBytes > 0 {
					Text(verbatim: "\($bytesDownloaded.wrappedValue.formattedByteCount) / \(totalBytes.formattedByteCount)")
						.contentTransition(.numericText())
				}
			}
			.font(.caption)
			.foregroundColor(.secondary)
		}
		.padding(.vertical, 4)
		.onReceive(download.$progress) { self.progress = $0 }
		.onReceive(download.$bytesDownloaded) { self.bytesDownloaded = $0 }
		.onReceive(download.$totalBytes) { self.totalBytes = $0 }
		.onReceive(download.$unpackageProgress) { self.unpackageProgress = $0 }
	}
	
	private var overallProgress: Double {
		download.onlyArchiving
			? unpackageProgress
			: (0.3 * unpackageProgress) + (0.7 * progress)
	}
}

private struct ZagImportGradientProgress: View {
    let progress: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmer = false

    private let colors: [Color] = [
        Color(red: 0, green: 0.86, blue: 1),
        Color(red: 0.05, green: 0.37, blue: 1),
        Color(red: 0.42, green: 0.18, blue: 1),
        Color(red: 0.95, green: 0.16, blue: 0.89),
        Color(red: 0, green: 0.86, blue: 1)
    ]

    var body: some View {
        GeometryReader { geometry in
            let fraction = min(max(progress, 0), 1)
            let filledWidth = geometry.size.width * fraction
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(
                            colors: colors,
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                    if !reduceMotion {
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.36), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: max(28, filledWidth * 0.38))
                        .offset(x: shimmer ? filledWidth : -max(28, filledWidth * 0.38))
                    }
                }
                .frame(width: filledWidth)
                .clipShape(Capsule())
            }
        }
        .animation(.easeOut(duration: 0.2), value: progress)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 2.1).repeatForever(autoreverses: false)) {
                shimmer = true
            }
        }
        .accessibilityLabel("Import progress")
        .accessibilityValue("\(Int(min(max(progress, 0), 1) * 100)) percent")
    }
}
