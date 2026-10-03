import Foundation
import UIKit

enum ZagSettingsBackup {
	struct Document: Codable {
		let formatVersion: Int
		let exportedAt: Date
		let appVersion: String
		let settings: [String: Value]
		let wallpaper: Data?

		init(
			formatVersion: Int,
			exportedAt: Date,
			appVersion: String,
			settings: [String: Value],
			wallpaper: Data? = nil
		) {
			self.formatVersion = formatVersion
			self.exportedAt = exportedAt
			self.appVersion = appVersion
			self.settings = settings
			self.wallpaper = wallpaper
		}
	}

	enum Value: Codable {
		case bool(Bool)
		case integer(Int)
		case double(Double)
		case string(String)
		case data(Data)

		private enum CodingKeys: String, CodingKey { case type, value }
		private enum Kind: String, Codable { case bool, integer, double, string, data }

		init(from decoder: Decoder) throws {
			let c = try decoder.container(keyedBy: CodingKeys.self)
			switch try c.decode(Kind.self, forKey: .type) {
			case .bool: self = .bool(try c.decode(Bool.self, forKey: .value))
			case .integer: self = .integer(try c.decode(Int.self, forKey: .value))
			case .double: self = .double(try c.decode(Double.self, forKey: .value))
			case .string: self = .string(try c.decode(String.self, forKey: .value))
			case .data: self = .data(try c.decode(Data.self, forKey: .value))
			}
		}

		func encode(to encoder: Encoder) throws {
			var c = encoder.container(keyedBy: CodingKeys.self)
			switch self {
			case .bool(let value):
				try c.encode(Kind.bool, forKey: .type); try c.encode(value, forKey: .value)
			case .integer(let value):
				try c.encode(Kind.integer, forKey: .type); try c.encode(value, forKey: .value)
			case .double(let value):
				try c.encode(Kind.double, forKey: .type); try c.encode(value, forKey: .value)
			case .string(let value):
				try c.encode(Kind.string, forKey: .type); try c.encode(value, forKey: .value)
			case .data(let value):
				try c.encode(Kind.data, forKey: .type); try c.encode(value, forKey: .value)
			}
		}

		var propertyListValue: Any {
			switch self {
			case .bool(let v): return v
			case .integer(let v): return v
			case .double(let v): return v
			case .string(let v): return v
			case .data(let v): return v
			}
		}
	}

	// Explicit allow-list: settings only. Certificate/private-key material,
	// pairing records, installed-app state and caches are intentionally excluded.
	static let exactKeys: Set<String> = [
		"Feather.userInterfaceStyle",
		"Feather.shouldTintIcons",
		"Feather.shouldChangeIconsBasedOffStyle",
		"Feather.storeCellAppearance",
		"Feather.userTintColor",
		"Feather.compressionLevel",
		"Feather.useShareSheetForArchiving",
		"Feather.installationMethod",
		"Feather.ipFix",
		"Feather.serverMethod",
		"signing_options",
		"ZagStore.disableIdleTimeout",
		"ZagStore.settingsSectionOrder",
		"ZagStore.settingsSectionSortMode",
		"ZagStore.advancedSettingsUnlocked",
		"zagStore.wallpaper.enabled",
		"zagStore.wallpaper.blur"
	]

	static let keyPrefixes = [
		"zagStore.designer.",
		"ZagStore.",
		"zagStore."
	]

	static func exportURL() throws -> URL {
		let defaults = UserDefaults.standard.dictionaryRepresentation()
		var values: [String: Value] = [:]

		for (key, raw) in defaults where shouldExport(key) {
			if let value = encodeValue(raw) {
				values[key] = value
			}
		}

		let document = Document(
			formatVersion: 1,
			exportedAt: Date(),
			appVersion: Bundle.main.version,
			settings: values,
			wallpaper: try? Data(contentsOf: ZagWallpaperStore.url)
		)
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		encoder.dateEncodingStrategy = .iso8601
		let data = try encoder.encode(document)

		let formatter = DateFormatter()
		formatter.dateFormat = "yyyy-MM-dd-HHmm"
		let name = "ZagStore-Settings-\(formatter.string(from: Date())).zagsettings"
		let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
		try data.write(to: url, options: .atomic)
		return url
	}

	static func importSettings(from url: URL) throws -> Int {
		let accessed = url.startAccessingSecurityScopedResource()
		defer { if accessed { url.stopAccessingSecurityScopedResource() } }

		let data = try Data(contentsOf: url)
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		let document = try decoder.decode(Document.self, from: data)
		guard document.formatVersion == 1 else {
			throw NSError(domain: "ZagSettingsBackup", code: 1, userInfo: [
				NSLocalizedDescriptionKey: "This settings backup uses an unsupported format."
			])
		}

		for (key, value) in document.settings where shouldExport(key) {
			UserDefaults.standard.set(value.propertyListValue, forKey: key)
		}
		UserDefaults.standard.synchronize()

		if let wallpaper = document.wallpaper {
			let directory = ZagWallpaperStore.url.deletingLastPathComponent()
			try FileManager.default.createDirectory(
				at: directory,
				withIntermediateDirectories: true
			)
			try wallpaper.write(to: ZagWallpaperStore.url, options: .atomic)
		} else if document.settings[ZagWallpaperStore.enabledKey] != nil {
			// A backup that explicitly contains wallpaper settings but no image
			// must not leave a stale wallpaper from the current installation behind.
			try? FileManager.default.removeItem(at: ZagWallpaperStore.url)
			UserDefaults.standard.set(false, forKey: ZagWallpaperStore.enabledKey)
		}

		if let data = UserDefaults.standard.data(forKey: "signing_options"),
		   let options = try? JSONDecoder().decode(Options.self, from: data) {
			OptionsManager.shared.options = options
			OptionsManager.shared.objectWillChange.send()
		}

		NotificationCenter.default.post(name: .zagWallpaperChanged, object: nil)
		return document.settings.count
	}

	private static func shouldExport(_ key: String) -> Bool {
		if exactKeys.contains(key) { return true }
		return keyPrefixes.contains { key.hasPrefix($0) }
			&& !key.lowercased().contains("history")
			&& !key.lowercased().contains("cache")
			&& !key.lowercased().contains("installed")
			&& !key.lowercased().contains("certificate")
			&& !key.lowercased().contains("pairing")
	}

	private static func encodeValue(_ raw: Any) -> Value? {
		if let value = raw as? Bool { return .bool(value) }
		if let value = raw as? Int { return .integer(value) }
		if let value = raw as? Double { return .double(value) }
		if let value = raw as? String { return .string(value) }
		if let value = raw as? Data { return .data(value) }
		if let number = raw as? NSNumber {
			if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
			return .double(number.doubleValue)
		}
		return nil
	}
}
