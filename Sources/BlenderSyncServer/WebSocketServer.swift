/// Generic WebSocket server actor used by ``BlenderSyncServer``.
///
/// Hosts an HTTP listener that upgrades `/ws` requests to WebSocket, JSON-decodes
/// incoming frames into the generic `Incoming` type, and JSON-encodes outgoing
/// `Outgoing` values. Connection lifetimes and broadcasts are managed for you.

import Foundation
import NIO
import NIOHTTP1
import NIOWebSocket
import Logging

/// Errors thrown by ``WebSocketServer`` and ``WebSocketConnection``.
public enum WebSocketServerError: Error {
    /// The server failed to bind its TCP socket (port in use, permission denied, etc.).
    case bindingFailed
    /// A low-level transport read/write error.
    case transportError
    /// An outgoing message could not be JSON-encoded.
    case encodingError
    /// An incoming message could not be JSON-decoded.
    case decodingError
    /// The operation was attempted on a closed connection.
    case connectionClosed
}

/// Generic actor-based WebSocket server.
///
/// `Incoming` is the message type decoded from inbound frames; `Outgoing` is
/// the type encoded to outbound frames. Both must be `Codable & Sendable`.
public actor WebSocketServer<Incoming: Codable & Sendable, Outgoing: Codable & Sendable> {
    private let host: String
    private let port: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    
    private var eventLoopGroup: EventLoopGroup?
    private var serverBootstrap: ServerBootstrap?
    private var serverChannel: Channel?
    private var connections: [ObjectIdentifier: WebSocketConnection<Incoming, Outgoing>] = [:]
    private var messageHandler: (@Sendable (Incoming, WebSocketConnection<Incoming, Outgoing>) async -> Void)?
    
    let logger: Logger

    /// Create a server bound to `host:port`.
    ///
    /// - Parameters:
    ///   - host: Interface to bind. Defaults to loopback.
    ///   - port: TCP port.
    ///   - logger: swift-log logger.
    ///   - encoder: JSON encoder used for outgoing frames.
    ///   - decoder: JSON decoder used for incoming frames.
    public init(
        host: String = "127.0.0.1",
        port: Int = 8080,
        logger: Logger = Logger(label: "WebSocketServer"),
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.host = host
        self.port = port
        self.logger = logger
        self.encoder = encoder
        self.decoder = decoder
    }
    
    /// Bind the socket and start accepting WebSocket upgrades on `/ws`.
    ///
    /// Throws ``WebSocketServerError/bindingFailed`` if the host/port cannot be bound.
    public func start() async throws {
        guard eventLoopGroup == nil else {
            logger.warning("Server already started")
            return
        }
        
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        eventLoopGroup = group
        
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let httpHandler = HTTPUpgradeHandler(server: self)
                let config = NIOHTTPServerUpgradeConfiguration(
                    upgraders: [NIOWebSocketServerUpgrader(
                        maxFrameSize: 10 * 1024 * 1024, // 10MB max frame size
                        shouldUpgrade: { channel, req in
                            return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                        },
                        upgradePipelineHandler: { channel, req in
                            let websocketHandler = WebSocketHandler(server: self)
                            return channel.pipeline.addHandler(websocketHandler).flatMap { _ in
                                // Trigger connection creation after WebSocket upgrade is complete
                                let connection = WebSocketConnection<Incoming, Outgoing>(
                                    channel: channel,
                                    server: self,
                                    encoder: self.encoder,
                                    decoder: self.decoder
                                )
                                websocketHandler.setConnection(connection)
                                
                                // Add to server's connection list
                                Task {
                                    await self.addConnection(connection)
                                }
                                
                                return channel.eventLoop.makeSucceededFuture(())
                            }
                        }
                    )],
                    completionHandler: { _ in
                        channel.pipeline.removeHandler(httpHandler, promise: nil)
                    }
                )
                
                return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: config)
                    .flatMap {
                        channel.pipeline.addHandler(httpHandler)
                    }
            }
        
        serverBootstrap = bootstrap
        
        do {
            serverChannel = try await bootstrap.bind(host: host, port: port).get()
            logger.info("WebSocket server started on \(host):\(port)")
        } catch {
            logger.error("Failed to bind server: \(error)")
            throw WebSocketServerError.bindingFailed
        }
    }
    
    /// Close all active connections and shut the listener down gracefully.
    public func stop() async {
        logger.info("Stopping WebSocket server...")
        
        for connection in connections.values {
            await connection.close()
        }
        connections.removeAll()
        
        try? await serverChannel?.close()
        serverChannel = nil
        
        try? await eventLoopGroup?.shutdownGracefully()
        eventLoopGroup = nil
        
        logger.info("WebSocket server stopped")
    }
    
    /// Send `message` to every currently-connected client concurrently.
    ///
    /// Per-connection send failures are logged and do not throw — one slow or
    /// broken client cannot block delivery to others.
    public func broadcast(_ message: Outgoing) async throws {
        guard !connections.isEmpty else { return }
        
        await withTaskGroup(of: Void.self) { group in
            for connection in connections.values {
                group.addTask {
                    do {
                        try await connection.send(message)
                    } catch {
                        self.logger.error("Failed to send message to connection: \(error)")
                    }
                }
            }
        }
    }
    
    
    internal func addConnection(_ connection: WebSocketConnection<Incoming, Outgoing>) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        logger.info("New WebSocket connection established. Total connections: \(connections.count)")
    }
    
    internal func removeConnection(_ connection: WebSocketConnection<Incoming, Outgoing>) {
        let id = ObjectIdentifier(connection)
        connections.removeValue(forKey: id)
        logger.info("WebSocket connection closed. Total connections: \(connections.count)")
    }
    
    /// Install a closure invoked for every successfully decoded inbound message.
    ///
    /// The handler runs on the server actor. Replace at any time; only the most
    /// recently installed handler is called.
    public func setMessageHandler(_ handler: @escaping @Sendable (Incoming, WebSocketConnection<Incoming, Outgoing>) async -> Void) {
        self.messageHandler = handler
    }
    
    internal func handleIncomingMessage(_ message: Incoming, from connection: WebSocketConnection<Incoming, Outgoing>) async {
        if let handler = messageHandler {
            await handler(message, connection)
        } else {
            logger.info("Received message from connection (no handler set)")
        }
    }
}

private final class HTTPUpgradeHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    
    private let server: any Actor
    
    init(server: any Actor) {
        self.server = server
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let request = unwrapInboundIn(data)
        
        switch request {
        case .head(let head):
            if head.uri == "/ws" {
                return
            }
            
            let response = HTTPResponseHead(
                version: head.version,
                status: .notFound
            )
            context.write(wrapOutboundOut(.head(response)), promise: nil)
            context.write(wrapOutboundOut(.end(nil)), promise: nil)
            context.flush()
            
        case .body, .end:
            break
        }
    }
}

private final class WebSocketHandler<Incoming: Codable & Sendable, Outgoing: Codable & Sendable>: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    
    private let server: WebSocketServer<Incoming, Outgoing>
    private var connection: WebSocketConnection<Incoming, Outgoing>?
    
    init(server: WebSocketServer<Incoming, Outgoing>) {
        self.server = server
    }
    
    func channelActive(context: ChannelHandlerContext) {
        // Connection will be set by the upgrade handler
        // This ensures the connection is only created after WebSocket upgrade is complete
    }
    
    func setConnection(_ connection: WebSocketConnection<Incoming, Outgoing>) {
        self.connection = connection
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        guard let connection = connection else { return }
        
        Task {
            await server.removeConnection(connection)
        }
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        
        guard let connection = connection else { return }
        
        Task {
            await connection.handleFrame(frame)
        }
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        Task {
            server.logger.error("WebSocket error: \(error)")
        }
        context.close(promise: nil)
    }
}
