import Foundation
import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
@preconcurrency import NIOIMAPCore
import Testing
@testable import SwiftMail

@Suite(.serialized, .timeLimit(.minutes(1)))
struct GmailLabelStoreAndRawSearchTests {

    // MARK: - STORE X-GM-LABELS

    @Test
    func testStoreWritesSystemLabelsAsAtomsAndUserLabelsAsModifiedUTF7() async throws {
        // A system label must stay an atom (`\Inbox`); a user label outside ASCII must go out
        // as modified UTF-7, the form Gmail reports in X-GM-LABELS, or Gmail files the message
        // under a different label.
        let wire = try await encode(StoreGmailLabelsCommand(
            identifierSet: UIDSet([UID(7), UID(9)]),
            labels: ["\\Inbox", "Wallive/稍后"],
            operation: .remove,
            silent: true
        ))

        #expect(wire.hasPrefix("A001 UID STORE 7,9 -X-GM-LABELS.SILENT (\\Inbox \"Wallive/&eg1UDg-\")"))
    }

    @Test
    func testStoreRoundTripsThroughServer() async throws {
        let (server, channel) = try await makeGmailHarness()

        let resultTask = Task {
            try await server.storeGmailLabels(["Work"], on: UIDSet([UID(42)]), operation: .add, silent: false)
        }

        guard let commandLine = try await nextOutboundLine(from: channel) else {
            Issue.record("Expected outbound UID STORE command")
            return
        }
        #expect(commandLine.contains("UID STORE 42 +X-GM-LABELS (\"Work\")"))

        try await respond(
            "* 1 FETCH (UID 42 X-GM-LABELS (\\Inbox \"Work\"))\r\nA001 OK Success\r\n",
            on: channel
        )
        try await resultTask.value
    }

    @Test
    func testStoreValidation() {
        #expect(throws: (any Error).self) {
            try StoreGmailLabelsCommand(identifierSet: UIDSet(), labels: ["Work"], operation: .add, silent: true).validate()
        }
        #expect(throws: (any Error).self) {
            try StoreGmailLabelsCommand(identifierSet: UIDSet([UID(1)]), labels: [], operation: .add, silent: true).validate()
        }
        #expect(throws: Never.self) {
            try StoreGmailLabelsCommand(identifierSet: UIDSet([UID(1)]), labels: [], operation: .replace, silent: true).validate()
        }
    }

    // MARK: - SEARCH X-GM-RAW

    @Test
    func testRawSearchScopesToUIDSetAndReturnsMatches() async throws {
        let (server, channel) = try await makeGmailHarness()

        let resultTask = Task {
            try await server.searchGmailRaw("category:promotions", in: UIDSet([UID(10), UID(11), UID(12)]))
        }

        guard let commandLine = try await nextOutboundLine(from: channel) else {
            Issue.record("Expected outbound UID SEARCH command")
            return
        }
        #expect(commandLine.contains("UID SEARCH UID 10:12 X-GM-RAW \"category:promotions\""))
        #expect(!commandLine.contains("CHARSET"))

        try await respond("* SEARCH 10 12\r\nA001 OK SEARCH completed\r\n", on: channel)
        let result = try await resultTask.value

        #expect(result.toArray() == [UID(10), UID(12)])
    }

    @Test
    func testRawSearchWithNonASCIIQuerySendsUTF8Charset() async throws {
        let (server, channel) = try await makeGmailHarness()
        let connection = IMAPNamedConnection(
            name: "gmail-raw-test",
            connection: await server.primaryConnection,
            authenticateOnConnection: { _ in }
        )

        let resultTask = Task { try await connection.searchGmailRaw("label:稍后") }

        guard let commandLine = try await nextOutboundLine(from: channel) else {
            Issue.record("Expected outbound UID SEARCH command")
            return
        }
        #expect(commandLine.contains("X-GM-RAW"))
        guard commandLine.contains("UID SEARCH CHARSET UTF-8") else {
            // Gmail's answer to a non-ASCII search without CHARSET.
            Issue.record("Expected CHARSET UTF-8: \(commandLine)")
            try await respond("A001 BAD Could not parse command\r\n", on: channel)
            _ = try? await resultTask.value
            return
        }

        // The UTF-8 query goes out as a literal; answer its continuation request.
        try await respond("+ go ahead\r\n", on: channel)
        _ = try await nextOutboundLine(from: channel)
        try await respond("* SEARCH 3\r\nA001 OK SEARCH completed\r\n", on: channel)

        #expect(try await resultTask.value.toArray() == [UID(3)])
    }

    // MARK: - Helpers

    private func encode(_ command: StoreGmailLabelsCommand) async throws -> String {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(command.toTaggedCommand(tag: "A001")))
        // Not awaited: a label sent as a literal holds the write open until a continuation request.
        channel.writeAndFlush(wrapped, promise: nil)
        guard var outbound = try await channel.readOutbound(as: ByteBuffer.self) else { return "" }
        return outbound.readString(length: outbound.readableBytes) ?? ""
    }

    private func respond(_ text: String, on channel: NIOAsyncTestingChannel) async throws {
        var response = channel.allocator.buffer(capacity: text.utf8.count)
        response.writeString(text)
        try await channel.writeInbound(response)
    }

    /// Wires an `IMAPServer`'s primary connection to an embedded channel, as in
    /// `FetchGmailAttributesTests`.
    private func makeGmailHarness() async throws -> (server: SwiftMail.IMAPServer, channel: NIOAsyncTestingChannel) {
        let server = SwiftMail.IMAPServer(host: "localhost", port: 143, useTLS: false)
        let connection = await server.primaryConnection

        let channel = NIOAsyncTestingChannel()
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 143)
        try await channel.connect(to: address)
        try await channel.addIMAPClientHandler()
        try await channel.pipeline.addHandler(connection.duplexLogger)
        try await channel.pipeline.addHandler(connection.responseBuffer)
        connection.replaceChannelForTesting(channel)

        return (server, channel)
    }

    private func nextOutboundLine(
        from channel: NIOAsyncTestingChannel,
        timeoutNanoseconds: UInt64 = 10_000_000_000
    ) async throws -> String? {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            if var line = try await channel.readOutbound(as: ByteBuffer.self) {
                return line.readString(length: line.readableBytes)
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return nil
    }
}
