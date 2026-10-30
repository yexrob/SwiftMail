import Foundation
import NIO
import NIOIMAPCore

/// Command for adding, removing or replacing Gmail labels (`UID STORE ... X-GM-LABELS`).
struct StoreGmailLabelsCommand: IMAPTaggedCommand {
    typealias ResultType = Void
    typealias HandlerType = StoreHandler

    /// The messages to update
    let identifierSet: UIDSet

    /// The labels as Gmail displays them: system labels such as `\Inbox` start with a backslash,
    /// user labels are encoded as modified UTF-7 on the wire.
    let labels: [String]

    /// The type of store operation
    let operation: StoreData.StoreType

    /// Whether the server omits the untagged FETCH with the resulting labels (`X-GM-LABELS.SILENT`)
    let silent: Bool

    let timeoutSeconds = 10

    func validate() throws {
        guard !identifierSet.isEmpty else { throw IMAPError.emptyIdentifierSet }
        guard !labels.isEmpty || operation == .replace else {
            throw IMAPError.invalidArgument("Gmail labels cannot be empty when adding or removing")
        }
        for label in labels where label.isEmpty {
            throw IMAPError.invalidArgument("Gmail label cannot be empty")
        }
    }

    func toTaggedCommand(tag: String) -> TaggedCommand {
        let gmailLabels = labels.map(Self.gmailLabel)
        let storeLabels: StoreGmailLabels
        switch operation {
            case .add: storeLabels = .add(silent: silent, gmailLabels: gmailLabels)
            case .remove: storeLabels = .remove(silent: silent, gmailLabels: gmailLabels)
            case .replace: storeLabels = .replace(silent: silent, gmailLabels: gmailLabels)
        }
        return TaggedCommand(tag: tag, command: .uidStore(
            .set(identifierSet.toNIOSet()), [], .gmailLabels(storeLabels)
        ))
    }

    /// System labels go out as atoms; user labels are encoded like mailbox names, the form
    /// `fetchGmailAttributes(for:)` decodes them from.
    private static func gmailLabel(_ label: String) -> GmailLabel {
        if label.hasPrefix("\\") { return GmailLabel(ByteBuffer(string: label)) }
        guard let path = try? MailboxPath.makeRootMailbox(displayName: label) else {
            return GmailLabel(ByteBuffer(string: label))
        }
        return GmailLabel(mailboxName: path.name)
    }
}
