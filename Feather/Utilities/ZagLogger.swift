//
//  ZagLogger.swift
//  Feather
//
//  Zag Store persistent diagnostic logging.
//

import Foundation

final class ZagLogger: ObservableObject {
	static let shared = ZagLogger()

	static let verboseKey = "ZagStore.verboseLogging"
	static let didChangeNotification = Notification.Name("ZagStore.logDidChange")

	enum Level: String {
		case info = "INFO"
		case warning = "WARN"
		case error = "ERROR"
		case debug = "DEBUG"
	}

	private let queue = DispatchQueue(label: "ZagStore.Logger", qos: .utility)
	private let maxBytes = 1_000_000
	private let trimToBytes = 750_000

	private init() {}

	var isVerboseEnabled: Bool {
		UserDefaults.standard.bool(forKey: Self.verboseKey)
	}

	var logURL: URL {
		let base = FileManager.default.urls(
			for: .applicationSupportDirectory,
			in: .userDomainMask
		).first ?? FileManager.default.temporaryDirectory
		let directory = base.appendingPathComponent("ZagStore", isDirectory: true)
		try? FileManager.default.createDirectory(
			at: directory,
			withIntermediateDirectories: true
		)
		return directory.appendingPathComponent("zag-store.log")
	}

	func info(_ category: String, _ message: @autoclosure () -> String) {
		guard isVerboseEnabled else { return }
		_write(level: .info, category: category, message: message())
	}

	func debug(_ category: String, _ message: @autoclosure () -> String) {
		guard isVerboseEnabled else { return }
		_write(level: .debug, category: category, message: message())
	}

	func warning(_ category: String, _ message: @autoclosure () -> String) {
		_write(level: .warning, category: category, message: message())
	}

	func error(_ category: String, _ message: @autoclosure () -> String) {
		_write(level: .error, category: category, message: message())
	}

	func read() -> String {
		queue.sync {
			(try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
		}
	}

	struct Snapshot {
		let text: String
		let byteCount: Int
		let entryCount: Int
		let lastEventDate: Date?
	}

	func snapshot() -> Snapshot {
		queue.sync {
			let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
			let data = Data(text.utf8)
			let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
			let lastDate = lines.last.flatMap { line -> Date? in
				guard let token = line.split(separator: " ", maxSplits: 1).first else { return nil }
				let formatter = ISO8601DateFormatter()
				formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
				return formatter.date(from: String(token))
			}
			return Snapshot(
				text: text,
				byteCount: data.count,
				entryCount: lines.count,
				lastEventDate: lastDate
			)
		}
	}

	func clear() {
		queue.async {
			try? FileManager.default.removeItem(at: self.logURL)
			DispatchQueue.main.async {
				NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
			}
		}
	}

	private func _write(level: Level, category: String, message: String) {
		let line = "\(_timestamp()) [\(level.rawValue)] [\(category)] \(message)\n"
		queue.async {
			let url = self.logURL
			let data = Data(line.utf8)
			if FileManager.default.fileExists(atPath: url.path),
			   let handle = try? FileHandle(forWritingTo: url) {
				defer { try? handle.close() }
				try? handle.seekToEnd()
				try? handle.write(contentsOf: data)
			} else {
				try? data.write(to: url, options: .atomic)
			}
			self._trimIfNeeded(url)
			DispatchQueue.main.async {
				NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
			}
		}
	}

	private func _trimIfNeeded(_ url: URL) {
		guard
			let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
			let size = attributes[.size] as? NSNumber,
			size.intValue > maxBytes,
			let data = try? Data(contentsOf: url)
		else { return }

		let keep = min(trimToBytes, data.count)
		let tail = data.suffix(keep)
		var trimmed = Data(tail)
		if let newline = trimmed.firstIndex(of: 0x0A), newline + 1 < trimmed.endIndex {
			trimmed = Data(trimmed[(newline + 1)...])
		}
		try? trimmed.write(to: url, options: .atomic)
	}

	private func _timestamp() -> String {
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		return formatter.string(from: Date())
	}
}
