import Foundation
import Combine
import Network

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
	private let advertiser = ZagPairableHostAdvertiser()

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

	var pairingFileExists: Bool {
		FileManager.default.fileExists(atPath: Self.pairingFileURL.path)
	}

	func start() {
		guard !isRunning else { return }
		advertiser.stop()
		state = .starting

		let started = "Zag Store".withCString { hostName in
			Self.pairingFileURL.path.withCString { outputPath in
				zag_rppairing_start(hostName, outputPath, zagRPPairingCallback)
			}
		}
		if !started { state = .failed("The RPPairing engine could not be started.") }
	}

	func resetStatus() {
		guard !isRunning else { return }
		advertiser.stop()
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
			let fields = message.split(separator: "|", omittingEmptySubsequences: false)
			state = .paired(
				name: fields.indices.contains(0) ? String(fields[0]) : "This iPhone",
				model: fields.indices.contains(1) ? String(fields[1]) : "",
				udid: fields.indices.contains(2) ? String(fields[2]) : ""
			)
		case -1:
			advertiser.stop()
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

	private static var pairingFileURL: URL {
		let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		return base
			.appendingPathComponent("ZagStore", isDirectory: true)
			.appendingPathComponent("rppairing.plist", isDirectory: false)
	}
}

@MainActor
private final class ZagPairableHostAdvertiser {
	private var listener: NWListener?
	private var relay: ZagPairRelay?

	func publish(
		rustPort: UInt16,
		identifier: String,
		txt: [String: String],
		failure: @escaping (String) -> Void
	) throws {
		stop()

		var record = NWTXTRecord()
		for (key, value) in txt { record[key] = value }

		let parameters = NWParameters.tcp
		parameters.includePeerToPeer = true
		let listener = try NWListener(using: parameters)
		listener.service = NWListener.Service(
			name: identifier,
			type: "_remotepairing-pairable-host._tcp",
			domain: "local",
			txtRecord: record
		)

		listener.stateUpdateHandler = { [weak self, weak listener] state in
			Task { @MainActor in
				guard let self, let listener, self.listener === listener else { return }
				switch state {
				case .failed(let error):
					failure("RPPairing Bonjour failed: \(error.localizedDescription)")
				case .waiting(let error):
					failure("RPPairing Bonjour is waiting: \(error.localizedDescription)")
				default:
					break
				}
			}
		}

		listener.newConnectionHandler = { [weak self, weak listener] incoming in
			Task { @MainActor in
				guard let self, let listener, self.listener === listener, self.relay == nil,
					  let port = NWEndpoint.Port(rawValue: rustPort) else {
					incoming.cancel()
					return
				}
				let outgoing = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
				let relay = ZagPairRelay(incoming: incoming, outgoing: outgoing) {
					failure("RPPairing connection relay failed.")
				}
				self.relay = relay
				relay.start()
			}
		}

		self.listener = listener
		listener.start(queue: .main)
	}

	func stop() {
		listener?.stateUpdateHandler = nil
		listener?.newConnectionHandler = nil
		listener?.cancel()
		listener = nil
		relay?.cancel()
		relay = nil
	}
}

private final class ZagPairRelay: @unchecked Sendable {
	private let incoming: NWConnection
	private let outgoing: NWConnection
	private let failure: () -> Void
	private var stopped = false

	init(incoming: NWConnection, outgoing: NWConnection, failure: @escaping () -> Void) {
		self.incoming = incoming
		self.outgoing = outgoing
		self.failure = failure
	}

	func start() {
		incoming.stateUpdateHandler = { [weak self] state in
			if case .failed = state { self?.fail() }
		}
		outgoing.stateUpdateHandler = { [weak self] state in
			guard let self else { return }
			switch state {
			case .ready:
				self.pump(from: self.incoming, to: self.outgoing)
				self.pump(from: self.outgoing, to: self.incoming)
			case .failed:
				self.fail()
			default:
				break
			}
		}
		incoming.start(queue: .main)
		outgoing.start(queue: .main)
	}

	func cancel() {
		guard !stopped else { return }
		stopped = true
		incoming.stateUpdateHandler = nil
		outgoing.stateUpdateHandler = nil
		incoming.cancel()
		outgoing.cancel()
	}

	private func fail() {
		guard !stopped else { return }
		cancel()
		failure()
	}

	private func pump(from source: NWConnection, to destination: NWConnection) {
		source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
			guard let self, !self.stopped else { return }
			guard error == nil else { self.fail(); return }
			destination.send(content: data, isComplete: complete, completion: .contentProcessed { [weak self] error in
				guard let self, !self.stopped else { return }
				if error != nil { self.fail(); return }
				if !complete { self.pump(from: source, to: destination) }
			})
		}
	}
}
