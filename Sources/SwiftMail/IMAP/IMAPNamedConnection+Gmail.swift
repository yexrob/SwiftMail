import Foundation
import NIOIMAPCore

extension IMAPNamedConnection {
    /// Whether this connection advertised Gmail's `X-GM-EXT-1` capability.
    public var supportsGmailExtensions: Bool {
        capabilities.containsGmailExtensionsCapability
    }

    /// Fetches Gmail-native attributes for the given UIDs on this named connection.
    ///
    /// Requires the `X-GM-EXT-1` capability; other IMAP servers answer with a
    /// tagged BAD. Gate calls on `supportsGmailExtensions`.
    public func fetchGmailAttributes(
        for identifierSet: UIDSet
    ) async throws -> [UID: GmailMessageAttributes] {
        let command = FetchGmailAttributesCommand(identifierSet: identifierSet)
        let records = try await executeCommand(command)

        var result: [UID: GmailMessageAttributes] = [:]
        for record in records {
            guard let uid = record.uid,
                  let messageID = record.messageID,
                  let threadID = record.threadID
            else { continue }
            result[uid] = GmailMessageAttributes(
                messageID: messageID,
                threadID: threadID,
                labels: record.labels
            )
        }
        return result
    }

    /// Adds, removes or replaces Gmail labels on the given UIDs in this named connection
    /// (`UID STORE ... X-GM-LABELS`).
    ///
    /// Labels take the form ``GmailMessageAttributes/labels`` reports: system labels such as
    /// `\Inbox` start with a backslash, user labels are plain names and go out as modified UTF-7.
    /// Removing `\Inbox` archives a message.
    /// Requires the `X-GM-EXT-1` capability; other IMAP servers answer with a tagged BAD.
    /// Gate calls on `supportsGmailExtensions`.
    ///
    /// - Parameters:
    ///   - labels: The labels to add, remove, or set as the complete set.
    ///   - identifierSet: The messages to update.
    ///   - operation: Add, remove, or replace.
    ///   - silent: Whether the server omits the untagged FETCH with the resulting labels.
    /// - Throws: `IMAPError.storeFailed` if the server refuses the store,
    ///   `IMAPError.emptyIdentifierSet` if the identifier set is empty.
    public func storeGmailLabels(
        _ labels: [String],
        on identifierSet: UIDSet,
        operation: StoreData.StoreType,
        silent: Bool = true
    ) async throws {
        let command = StoreGmailLabelsCommand(
            identifierSet: identifierSet,
            labels: labels,
            operation: operation,
            silent: silent
        )
        try await executeCommand(command)
    }

    /// Searches this named connection with a query in the Gmail web search syntax (`UID SEARCH X-GM-RAW`),
    /// such as `category:promotions`.
    ///
    /// Requires the `X-GM-EXT-1` capability; other IMAP servers answer with a tagged BAD.
    /// Gate calls on `supportsGmailExtensions`.
    ///
    /// - Parameters:
    ///   - query: The Gmail search query.
    ///   - identifierSet: Optional set of UIDs to search within. If nil, searches all messages.
    /// - Returns: The UIDs of the matching messages.
    /// - Throws: `IMAPError.searchRejected` if the server refuses the search.
    public func searchGmailRaw(
        _ query: String,
        in identifierSet: UIDSet? = nil
    ) async throws -> UIDSet {
        let command = SearchCommand<UID>(identifierSet: identifierSet, criteria: [.gmailRaw(query)])
        return try await executeCommand(command)
    }
}
