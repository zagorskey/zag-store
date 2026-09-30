import Foundation
import Combine
import OSLog
import UIKit

private let zagRPPairingLog = Logger(subsystem: "com.cwd43.gu29.rppairing", category: "Transport")

private func zagGate2Callback(_ code: Int32, _ message: UnsafePointer<CChar>?) {
	let text = message.map { String(cString: $0) } ?? ""
	DispatchQueue.main.async {
		ZagRPPairingCore.shared.receiveGate2(code: code, message: text)
	}
}

private func zagRPPairingCallback(_ code: Int32, _ message: UnsafePointer<CChar>?) {
	let text = message.map { String(cString: $0) } ?? ""
	DispatchQueue.main.async {
		ZagRPPairingCore.shared.receive(code: code, message: text)
	}
}

@MainActor
final class ZagRPPairingCore: ObservableObject {
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

	enum Gate2State: Equatable {
		case idle
		case starting
		case lockdown(String)
		case pairing(String)
		case pairRecord(String)
		case coreDevice(String)
		case rsd(String)
		case complete(name: String, model: String, version: String, build: String)
		case failed(String)
	}

	@Published private(set) var gate2State: Gate2State = .idle
	private let advertiser = ZagPairableHostAdvertiser()
	private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

	static var version: String {
		guard let pointer = zag_rppairing_core_version() else { return "Unavailable" }
		defer { zag_rppairing_string_free(pointer) }
		return String(cString: pointer)
	}

	var isRunning: Bool {
		switch state {
		case .starting, .advertising, .connected, .pin: return true
		default: return false
		}
	}

	var isGate2Running: Bool {
		switch gate2State {
		case .starting, .lockdown, .pairing, .pairRecord, .coreDevice, .rsd:
			return true
		default:
			return false
		}
	}

	var lockdownPairingFileExists: Bool {
		FileManager.default.fileExists(atPath: Self.lockdownPairingFileURL.path)
	}

	func startGate2Probe(deviceIP: String = "10.7.0.1") {
		guard !isGate2Running else { return }
		gate2State = .starting
		let started = deviceIP.withCString { ip in
			Self.lockdownPairingFileURL.path.withCString { outputPath in
				zag_gate2_probe(ip, outputPath, zagGate2Callback)
			}
		}
		if !started {
			gate2State = .failed("The Gate 2 probe could not be started.")
		}
	}

	fileprivate func receiveGate2(code: Int32, message: String) {
		switch code {
		case 101:
			gate2State = .starting
		case 102:
			gate2State = .lockdown(message)
		case 103:
			gate2State = .pairing(message)
		case 104:
			gate2State = .pairRecord(message)
		case 105:
			gate2State = .coreDevice(message)
		case 106:
			gate2State = .rsd(message)
		case 107:
			let fields = message.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
			gate2State = .complete(
				name: fields.indices.contains(0) ? fields[0] : "This iPhone",
				model: fields.indices.contains(1) ? fields[1] : "",
				version: fields.indices.contains(2) ? fields[2] : "",
				build: fields.indices.contains(3) ? fields[3] : ""
			)
		case -2:
			gate2State = .failed(message)
		default:
			break
		}
	}

	var pairingFileExists: Bool {
		FileManager.default.fileExists(atPath: Self.pairingFileURL.path)
	}

	func start() {
		guard !isRunning else { return }
		advertiser.stop()
		beginPairingBackgroundTime()
		state = .starting

		let started = "Zag Store".withCString { hostName in
			Self.pairingFileURL.path.withCString { outputPath in
				zag_rppairing_start(hostName, outputPath, zagRPPairingCallback)
			}
		}
		if !started {
			endPairingBackgroundTime()
			state = .failed("The RPPairing engine could not be started.")
		}
	}

	func resetStatus() {
		guard !isRunning else { return }
		advertiser.stop()
		endPairingBackgroundTime()
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
			advertiser.stop()
			endPairingBackgroundTime()
			let fields = message.split(separator: "|", omittingEmptySubsequences: false)
			state = .paired(
				name: fields.indices.contains(0) ? String(fields[0]) : "This iPhone",
				model: fields.indices.contains(1) ? String(fields[1]) : "",
				udid: fields.indices.contains(2) ? String(fields[2]) : ""
			)
		case -1:
			advertiser.stop()
			endPairingBackgroundTime()
			state = .failed(message)
		default:
			break
		}
	}

	private func startNativeBonjour(from payload: String) {
		let lines = payload.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
		guard lines.count >= 2, let rustPort = UInt16(lines[0]), rustPort > 0 else {
			state = .failed("RPPairing returned invalid listener metadata.")
			return
		}
		let identifier = lines[1]
		guard !identifier.isEmpty else {
			state = .failed("RPPairing returned an empty service identifier.")
			return
		}

		var txt: [String: String] = [:]
		for line in lines.dropFirst(2) {
			guard let separator = line.firstIndex(of: "=") else { continue }
			let key = String(line[..<separator])
			let value = String(line[line.index(after: separator)...])
			if !key.isEmpty { txt[key] = value }
		}

		do {
			try advertiser.publish(
				rustPort: rustPort,
				identifier: identifier,
				txt: txt,
				failure: { [weak self] message in
					Task { @MainActor in
						self?.state = .failed(message)
					}
				}
			)
			state = .advertising
		} catch {
			state = .failed("Native RPPairing advertisement failed: \(error.localizedDescription)")
		}
	}

	private func beginPairingBackgroundTime() {
		guard backgroundTask == .invalid else { return }
		backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Zag RPPairing") { [weak self] in
			Task { @MainActor in
				guard let self else { return }
				self.advertiser.stop()
				self.endPairingBackgroundTime()
				if self.isRunning {
					self.state = .failed("RPPairing background time expired. Keep Zag Store open and try again.")
				}
			}
		}
	}

	private func endPairingBackgroundTime() {
		guard backgroundTask != .invalid else { return }
		UIApplication.shared.endBackgroundTask(backgroundTask)
		backgroundTask = .invalid
	}

	private static var lockdownPairingFileURL: URL {
		let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		return base
			.appendingPathComponent("ZagStore", isDirectory: true)
			.appendingPathComponent("lockdown-pairing.plist", isDirectory: false)
	}

	private static var pairingFileURL: URL {
		let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		return base
			.appendingPathComponent("ZagStore", isDirectory: true)
			.appendingPathComponent("rppairing.plist", isDirectory: false)
	}
}

@MainActor
private final class ZagPairableHostAdvertiser: NSObject, NetServiceDelegate {
	private var service: NetService?
	private var failure: ((String) -> Void)?

	func publish(
		rustPort: UInt16,
		identifier: String,
		txt: [String: String],
		failure: @escaping (String) -> Void
	) throws {
		stop()
		self.failure = failure

		var txtRecord: [String: Data] = [:]
		for (key, value) in txt {
			txtRecord[key] = Data(value.utf8)
		}

		let service = NetService(
			domain: "",
			type: "_remotepairing-pairable-host._tcp.",
			name: identifier,
			port: Int32(rustPort)
		)
		service.delegate = self
		if !txtRecord.isEmpty {
			service.setTXTRecord(NetService.data(fromTXTRecord: txtRecord))
		}
		self.service = service
		zagRPPairingLog.notice("publishing Rust listener directly on port \(rustPort)")
		service.publish()
	}

	func stop() {
		service?.stop()
		service?.delegate = nil
		service = nil
		failure = nil
	}

	func netServiceDidPublish(_ sender: NetService) {
		zagRPPairingLog.notice("direct Bonjour published on port \(sender.port)")
	}

	func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
		let code = errorDict[NetService.errorCode]?.intValue ?? -1
		zagRPPairingLog.error("direct Bonjour failed: \(code)")
		let callback = failure
		stop()
		callback?("RPPairing Bonjour advertisement failed (\(code)).")
	}
}
