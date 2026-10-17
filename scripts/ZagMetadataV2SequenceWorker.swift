import Foundation

/// Dedicated worker for exercising the sequence store from independent processes.
/// Usage: worker <state-file> <channel> <sequence>
@main
struct ZagMetadataV2SequenceWorker {
    static func main() {
        guard CommandLine.arguments.count == 4,
              let sequence = Int(CommandLine.arguments[3]) else {
            fputs("Usage: worker <state-file> <channel> <sequence>\n", stderr)
            exit(2)
        }
        let file = URL(fileURLWithPath: CommandLine.arguments[1])
        let channel = CommandLine.arguments[2]
        do {
            try ZagMetadataV2SequenceStore(fileURL: file).accept(
                channel: channel,
                sequence: sequence,
                signedPayload: Data("sequence-\(sequence)".utf8))
            print("ACCEPTED \(sequence)")
        } catch ZagMetadataV2SequenceStore.StoreError.rollback {
            print("ROLLBACK_REJECTED \(sequence)")
        } catch {
            fputs("UNEXPECTED_FAILURE \(sequence): \(error)\n", stderr)
            exit(1)
        }
    }
}
