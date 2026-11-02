import Foundation
import NIO
import Testing
@testable import SwiftMail

/// A connection through a proxy opens the tunnel before TLS, and TLS inside it names the mail server: a responder on
/// 127.0.0.1 plays the proxy and records what the client sends. A handler order that puts TLS ahead of the tunnel
/// sends a ClientHello where the proxy expects its handshake; a tunnel built with the proxy's address as the TLS host
/// sends no SNI (an IP address) or the wrong one.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct MailProxyTunnelTests {
    static let mailHost = "imap.example.test"

    @Test(arguments: [ProxyResponder.Kind.socks5, .httpConnect])
    func tunnelOpensBeforeTLSAndTLSNamesTheMailServer(kind: ProxyResponder.Kind) async throws {
        try await withEventLoopGroup { group in
            let responder = ProxyResponder(kind: kind, group: group)
            let port = try await responder.start()
            let proxy: MailProxy = kind == .socks5 ? .socks5(host: "127.0.0.1", port: port) : .httpConnect(host: "127.0.0.1", port: port)
            let server = IMAPServer(host: Self.mailHost, port: 993, proxy: proxy)

            async let connect: Void = server.connect()
            let seen = try await responder.seen.futureResult.get()
            _ = try? await connect
            try? await server.disconnect()
            await responder.stop()

            #expect(seen.target == "\(Self.mailHost):993")
            #expect(seen.afterTunnel.first == 0x16, "a TLS handshake record follows the tunnel")
            #expect(seen.afterTunnel.firstRange(of: Array(Self.mailHost.utf8)) != nil, "the ClientHello carries the mail server as SNI")
        }
    }
}

/// A SOCKS5 or HTTP CONNECT proxy that opens no onward connection: it answers the handshake with success, records the
/// target and the first bytes sent through the tunnel, and closes.
final class ProxyResponder: @unchecked Sendable {
    enum Kind: Sendable { case socks5, httpConnect }

    struct Seen: Sendable {
        var target: String
        var afterTunnel: [UInt8]
    }

    let kind: Kind
    let group: EventLoopGroup
    let seen: EventLoopPromise<Seen>
    private var channel: Channel?

    init(kind: Kind, group: EventLoopGroup) {
        self.kind = kind
        self.group = group
        seen = group.next().makePromise(of: Seen.self)
    }

    func start() async throws -> Int {
        let kind = kind
        let seen = seen
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { child in
                child.eventLoop.makeCompletedFuture { try child.pipeline.syncOperations.addHandler(Handler(kind: kind, seen: seen)) }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        self.channel = channel
        return channel.localAddress!.port!
    }

    func stop() async {
        seen.fail(ChannelError.ioOnClosedChannel)
        try? await channel?.close().get()
    }

    private final class Handler: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        let kind: Kind
        let seen: EventLoopPromise<Seen>
        var bytes: [UInt8] = []
        var target: String?
        var tunnelStart = 0
        var greeted = false

        init(kind: Kind, seen: EventLoopPromise<Seen>) {
            self.kind = kind
            self.seen = seen
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            bytes += buffer.readBytes(length: buffer.readableBytes) ?? []
            if target == nil {
                switch kind {
                    case .socks5: socks(context: context)
                    case .httpConnect: http(context: context)
                }
            }
            // A ClientHello fits in one segment from a local client; the record header names its length.
            if let target, bytes.count >= tunnelStart + 5 {
                let after = Array(bytes[tunnelStart...])
                let length = after[0] == 0x16 ? Int(after[3]) << 8 | Int(after[4]) : 0
                if after[0] != 0x16 || after.count >= 5 + length {
                    seen.succeed(Seen(target: target, afterTunnel: after))
                    context.close(promise: nil)
                }
            }
        }

        private func socks(context: ChannelHandlerContext) {
            if !greeted {
                // VER 5, NMETHODS, METHODS. A first byte other than 5 is not a SOCKS greeting.
                guard bytes.first == 0x05 else { return fail(context, "not a SOCKS greeting: \(bytes.prefix(4))") }
                guard bytes.count >= 2, bytes.count >= 2 + Int(bytes[1]) else { return }
                greeted = true
                bytes.removeFirst(2 + Int(bytes[1]))
                write(context, [0x05, 0x00])
            }
            // VER CMD RSV ATYP=3 LEN host PORT
            guard bytes.count >= 5, bytes[3] == 0x03 else { return }
            let length = Int(bytes[4])
            guard bytes.count >= 5 + length + 2 else { return }
            let host = String(decoding: bytes[5..<(5 + length)], as: UTF8.self)
            let port = Int(bytes[5 + length]) << 8 | Int(bytes[6 + length])
            target = "\(host):\(port)"
            tunnelStart = 7 + length
            write(context, [0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        }

        private func http(context: ChannelHandlerContext) {
            guard bytes.first != 0x16 else { return fail(context, "a ClientHello before CONNECT") }
            guard let end = bytes.firstRange(of: Array("\r\n\r\n".utf8)) else { return }
            let head = String(decoding: bytes[..<end.lowerBound], as: UTF8.self)
            let parts = head.split(separator: "\r\n").first?.split(separator: " ") ?? []
            guard parts.count == 3, parts[0] == "CONNECT" else { return fail(context, "not a CONNECT request: \(head)") }
            target = String(parts[1])
            tunnelStart = end.upperBound
            write(context, Array("HTTP/1.1 200 Connection established\r\n\r\n".utf8))
        }

        private func write(_ context: ChannelHandlerContext, _ bytes: [UInt8]) {
            context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(bytes: bytes)), promise: nil)
        }

        private func fail(_ context: ChannelHandlerContext, _ reason: String) {
            seen.succeed(Seen(target: reason, afterTunnel: []))
            context.close(promise: nil)
        }
    }
}
