import Foundation
import Network

/// The current network path, for diagnostics only. Never used to restrict
/// or change refresh behaviour.
final class ZagNetworkPath {
	static let shared = ZagNetworkPath()

	private let monitor = NWPathMonitor()
	private let lock = NSLock()
	private var path: NWPath?

	private init() {
		monitor.pathUpdateHandler = { [weak self] path in
			guard let self else { return }
			self.lock.lock()
			self.path = path
			self.lock.unlock()
		}
		monitor.start(queue: DispatchQueue(label: "ZagNetworkPath"))
	}

	/// "Wi-Fi", "Mobile Data", "Wired", "Other", "Offline" or "Unknown",
	/// plus Low Data Mode and expensive flags.
	var summary: String {
		lock.lock()
		let path = self.path
		lock.unlock()
		guard let path else { return "Unknown" }
		guard path.status == .satisfied else { return "Offline" }
		// A VPN (LOCAL VPN included) can make the path use a virtual
		// interface; the available physical interfaces still tell the truth.
		let types = path.availableInterfaces.map(\.type)
		func uses(_ type: NWInterface.InterfaceType) -> Bool {
			path.usesInterfaceType(type) || types.contains(type)
		}
		let kind: String
		if uses(.wifi) {
			kind = "Wi-Fi"
		} else if uses(.cellular) {
			kind = "Mobile Data"
		} else if uses(.wiredEthernet) {
			kind = "Wired"
		} else {
			kind = "Other"
		}
		var flags: [String] = []
		if path.isConstrained { flags.append("Low Data Mode") }
		if path.isExpensive { flags.append("expensive") }
		return flags.isEmpty ? kind : kind + " (" + flags.joined(separator: ", ") + ")"
	}
}
