import Foundation
import NIO
import NIOSOCKS

/// A proxy the IMAP and SMTP connections of a server go through.
///
/// With a proxy, the TCP connection goes to the proxy's address, a tunnel to the mail server's host and port opens
/// in it, and TLS runs inside the tunnel with the mail server's host as SNI and certificate name. The proxy sees the
/// target host and port, not the mail.
public enum MailProxy: Sendable, Hashable, CustomStringConvertible {
    /// A SOCKS5 proxy with no authentication. The proxy resolves the mail server's host name.
    case socks5(host: String, port: Int)
    /// An HTTP proxy that takes `CONNECT host:port`.
    case httpConnect(host: String, port: Int)

    public var host: String {
        switch self {
            case .socks5(let host, _), .httpConnect(let host, _): return host
        }
    }

    public var port: Int {
        switch self {
            case .socks5(_, let port), .httpConnect(_, let port): return port
        }
    }

    public var description: String {
        switch self {
            case .socks5(let host, let port): return "socks5 \(host):\(port)"
            case .httpConnect(let host, let port): return "http-connect \(host):\(port)"
        }
    }
}

/// A connection through a ``MailProxy`` that failed before the mail server answered.
public struct MailProxyError: Error, Sendable, Hashable, CustomStringConvertible {
    public enum Reason: Sendable, Hashable {
        /// The TCP connection to the proxy failed: refused, or no answer.
        case proxyUnreachable
        /// The proxy answered and could not open the tunnel to the mail server. The text is the SOCKS reply or the
        /// HTTP status line.
        case targetUnreachable(String)
        /// The proxy asks for a user name and password, which ``MailProxy`` does not carry.
        case authenticationRequired
    }

    public let reason: Reason
    public let proxy: MailProxy

    public init(_ reason: Reason, proxy: MailProxy) {
        self.reason = reason
        self.proxy = proxy
    }

    public var description: String {
        switch reason {
            case .proxyUnreachable: return "Cannot reach the proxy \(proxy)"
            case .targetUnreachable(let text): return "The proxy \(proxy) cannot reach the server: \(text)"
            case .authenticationRequired: return "The proxy \(proxy) requires authentication"
        }
    }
}

/// The handlers that open a tunnel through a proxy, and a promise that completes when the tunnel is up or fails.
///
/// The connection's channel initializer adds ``handlers`` ahead of the TLS handler: the tunnel handler holds writes
/// until the proxy answers, so the ClientHello waits for the tunnel. The caller fails its greeting promise with the
/// tunnel's error, so a refused tunnel surfaces as a ``MailProxyError`` and not as a greeting timeout.
struct MailProxyTunnel {
    let proxy: MailProxy
    let established: EventLoopPromise<Void>

    /// The handlers for a channel to `host:port`, the mail server.
    func handlers(host: String, port: Int) -> [ChannelHandler] {
        switch proxy {
            case .socks5:
                return [
                    SOCKSClientHandler(targetAddress: .domain(host, port: port)),
                    SOCKSTunnelWatcher(proxy: proxy, established: established)
                ]
            case .httpConnect:
                return [HTTPConnectTunnelHandler(target: "\(host):\(port)", proxy: proxy, established: established)]
        }
    }

    /// The error for a failed TCP connect to the proxy.
    func connectFailed(_ error: Error) -> MailProxyError {
        let mapped = MailProxyError(.proxyUnreachable, proxy: proxy)
        established.fail(mapped)
        return mapped
    }
}

/// Completes the tunnel's promise from `SOCKSClientHandler`'s event and errors, and turns its errors into
/// ``MailProxyError``.
final class SOCKSTunnelWatcher: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let proxy: MailProxy
    private let established: EventLoopPromise<Void>

    init(proxy: MailProxy, established: EventLoopPromise<Void>) {
        self.proxy = proxy
        self.established = established
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is SOCKSProxyEstablishedEvent {
            established.succeed(())
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        let mapped: Error
        switch error {
            case let failed as SOCKSError.ConnectionFailed:
                mapped = MailProxyError(.targetUnreachable("SOCKS reply \(failed.reply.value)"), proxy: proxy)
            case is SOCKSError.NoValidAuthenticationMethod, is SOCKSError.InvalidAuthenticationSelection:
                mapped = MailProxyError(.authenticationRequired, proxy: proxy)
            default:
                mapped = error
        }
        established.fail(mapped)
        context.fireErrorCaught(mapped)
    }

    func channelInactive(context: ChannelHandlerContext) {
        established.fail(MailProxyError(.targetUnreachable("closed before the tunnel opened"), proxy: proxy))
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        established.fail(MailProxyError(.targetUnreachable("closed before the tunnel opened"), proxy: proxy))
    }
}

/// An HTTP `CONNECT` tunnel: sends the request when the channel turns active, holds writes until the proxy answers,
/// passes on the bytes after the response header, and closes the channel on a status other than 2xx.
final class HTTPConnectTunnelHandler: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    /// A response header longer than this is not an HTTP proxy's answer.
    static let headerLimit = 16 * 1024

    private let target: String
    private let proxy: MailProxy
    private let established: EventLoopPromise<Void>
    private var open = false
    private var sent = false
    private var header: ByteBuffer?
    private var pending: [(NIOAny, EventLoopPromise<Void>?)] = []

    init(target: String, proxy: MailProxy, established: EventLoopPromise<Void>) {
        self.target = target
        self.proxy = proxy
        self.established = established
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive { sendRequest(context: context) }
    }

    func channelActive(context: ChannelHandlerContext) {
        sendRequest(context: context)
        context.fireChannelActive()
    }

    private func sendRequest(context: ChannelHandlerContext) {
        guard !sent else { return }
        sent = true
        var buffer = context.channel.allocator.buffer(capacity: 2 * target.utf8.count + 40)
        buffer.writeString("CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n\r\n")
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if open {
            context.fireChannelRead(data)
            return
        }
        var incoming = unwrapInboundIn(data)
        if header == nil {
            header = incoming
        } else {
            header!.writeBuffer(&incoming)
        }
        let view = header!.readableBytesView
        guard let end = view.firstRange(of: [13, 10, 13, 10]) else {
            if view.count > Self.headerLimit { fail(context: context, MailProxyError(.targetUnreachable("no HTTP response"), proxy: proxy)) }
            return
        }
        let headerLength = end.upperBound - view.startIndex
        let text = header!.readString(length: headerLength) ?? ""
        let statusLine = text.prefix { $0 != "\r" }
        let parts = statusLine.split(separator: " ", maxSplits: 2)
        let status = parts.count >= 2 && parts[0].hasPrefix("HTTP/") ? Int(parts[1]) : nil
        switch status {
            case .some(200..<300):
                break
            case .some(407):
                fail(context: context, MailProxyError(.authenticationRequired, proxy: proxy))
                return
            default:
                fail(context: context, MailProxyError(.targetUnreachable(String(statusLine)), proxy: proxy))
                return
        }
        open = true
        let rest = header!
        header = nil
        established.succeed(())
        for (data, promise) in pending { context.write(data, promise: promise) }
        pending = []
        context.flush()
        if rest.readableBytes > 0 { context.fireChannelRead(wrapInboundOut(rest)) }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        if open {
            context.write(data, promise: promise)
        } else {
            pending.append((data, promise))
        }
    }

    func flush(context: ChannelHandlerContext) {
        if open { context.flush() }
    }

    func channelInactive(context: ChannelHandlerContext) {
        failPending(MailProxyError(.targetUnreachable("closed before the tunnel opened"), proxy: proxy))
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        failPending(MailProxyError(.targetUnreachable("closed before the tunnel opened"), proxy: proxy))
    }

    private func fail(context: ChannelHandlerContext, _ error: MailProxyError) {
        failPending(error)
        context.fireErrorCaught(error)
        context.close(promise: nil)
    }

    private func failPending(_ error: Error) {
        established.fail(error)
        let writes = pending
        pending = []
        for (_, promise) in writes { promise?.fail(error) }
    }
}
