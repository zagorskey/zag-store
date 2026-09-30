import Foundation

enum ZagRPPairingCore {
	static var version: String {
		guard let pointer = zag_rppairing_core_version() else {
			return "Unavailable"
		}
		defer { zag_rppairing_string_free(pointer) }
		return String(cString: pointer)
	}
}
