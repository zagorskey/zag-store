import Foundation
import Combine

private func zagRPPairingCallback(_ code: Int32, _ message: UnsafePointer<CChar>?) {
	let text = message.map { String(cString: $0) } ?? ""
	DispatchQueue.main.async {
		ZagRPPairingCore.shared.receive(code: code, message: text)
	}
}

@MainActor
final class ZagRPPairingCore: NSObject, ObservableObject, NetServiceDelegate {
	static let shared = ZagRPPairingCore()

	enum State: Equatable {
		case idle
		case starting
		case advertising
		case connected
		case pin(String)
		case paired(name: String, model: String, udid: String)
		case failed(String)
	}

	@Published private(set) var state: State = .idle
	private var pairingService: NetService?

	private override init() {
		super.init()
	}

	static var version: String {
		guard let pointer = zag_rppairing_core_version() else {
			return "Unavailable"
		}
		defer { zag_rppairing_string_free(pointer) }
		return String(cString: pointer)
	}

	var isRunning: Bool {
		switch state {
		case .starting, .advertising, .connected, .pin:
			return true
		default:
			return false
		}
	}

	var pairingFileExists: Bool {
		FileManager.default.fileExists(atPath: Self.pairingFileURL.path)
	}

	func start() {
		guard !isRunning else { return }
		stopBonjour()
		state = .starting

		let started = "Zag Store".withCString { hostName in
			Self.pairingFileURL.path.withCString { outputPath in
				zag_rppairing_start(hostName, outputPath, zagRPPairingCallback)
			}
		}

		if !started {
			state = .failed("The RPPairing engine could not be started.")
		}
	}

	func resetStatus() {
		guard !isRunning else { return }
		stopBonjour()
		state = .idle
	}

	fileprivate func receive(code: Int32, message: String) {
		switch code {
		case 1:
			state = .starting
		case 2:
			startNativeBonjour(from: message)
		case 3:
			state = .connected
		case 4:
			state = .pin(message)
		case 5:
			stopBonjour()
			let fields = message.split(separator: "|", omittingEmptySubsequences: false)
			state = .paired(
				name: fields.indices.contains(0) ? String(fields[0]) : "This iPhone",
				model: fields.indices.contains(1) ? String(fields[1]) : "",
				udid: fields.indices.contains(2) ? String(fields[2]) : ""
			)
		case -1:
			stopBonjour()
			state = .failed(message)
		default:
			break
		}
	}

	private func startNativeBonjour(from payload: String) {
		let lines = payload.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
		guard lines.count >= 2, let port = Int32(lines[0]), port > 0 else {
			state = .failed("RPPairing returned invalid Bonjour listener metadata.")
			return
		}

		let serviceName = lines[1]
		guard !serviceName.isEmpty else {
			state = .failed("RPPairing returned an empty Bonjour service identifier.")
			return
		}

		var txt: [String: Data] = [:]
		for line in lines.dropFirst(2) {
			guard let separator = line.firstIndex(of: "=") else { continue }
			let key = String(line[..<separator])
			let value = String(line[line.index(after: separator)...])
			guard !key.isEmpty else { continue }
			txt[key] = Data(value.utf8)
		}

		stopBonjour()
		let service = NetService(
			domain: "local.",
			type: "_remotepairing-pairable-host._tcp.",
			name: serviceName,
			port: port
		)
		service.delegate = self
		if !txt.isEmpty {
			service.setTXTRecord(NetService.data(fromTXTRecord: txt))
		}
		pairingService = service
		service.publish()
		state = .advertising
	}

	private func stopBonjour() {
		pairingService?.stop()
		pairingService?.delegate = nil
		pairingService = nil
	}

	func netServiceDidPublish(_ sender: NetService) {
		state = .advertising
	}

	func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]) {
		stopBonjour()
		let code = errorDict[NetService.errorCode]?.intValue ?? -1
		state = .failed("Native Bonjour advertisement failed (\(code)).")
	}

	private static var pairingFileURL: URL {
		let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		return base
			.appendingPathComponent("ZagStore", isDirectory: true)
			.appendingPathComponent("rppairing.plist", isDirectory: false)
	}
}
