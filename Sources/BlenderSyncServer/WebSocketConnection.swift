/// A single client WebSocket connection owned by ``WebSocketServer``.
///
/// Handles fragmentation, JSON decoding, and ping/pong. Inbound messages are
/// surfaced both through ``messageStream`` (per-connection) and through the
/// server's installed message handler.

import Foundation
import NIO
import NIOWebSocket
import Logging

/// An upgraded WebSocket connection managed by ``WebSocketServer``.
public final class WebSocketConnection<Incoming: Codable & Sendable, Outgoing: Codable & Sendable>: Sendable {
    private let channel: Channel
    private let server: WebSocketServer<Incoming, Outgoing>
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let logger: Logger
    
    private let messageStreamContinuation: AsyncThrowingStream<Incoming, Error>.Continuation
    /// Per-connection async stream of decoded inbound messages.
    ///
    /// Finishes when the connection closes. Yields the same values that are
    /// dispatched to the server's installed message handler.
    public let messageStream: AsyncThrowingStream<Incoming, Error>
    
    // Frame continuation handling
    private var partialTextMessage: String = ""
    private var partialBinaryMessage: Data = Data()
    private var isReceivingFragmentedMessage = false
    
    init(
        channel: Channel,
        server: WebSocketServer<Incoming, Outgoing>,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder(),
        logger: Logger = Logger(label: "WebSocketConnection")
    ) {
        self.channel = channel
        self.server = server
        self.encoder = encoder
        self.decoder = decoder
        self.logger = logger
        
        let (stream, continuation) = AsyncThrowingStream<Incoming, Error>.makeStream()
        self.messageStream = stream
        self.messageStreamContinuation = continuation
    }
    
    deinit {
        messageStreamContinuation.finish()
    }
    
    /// Send a single message as a binary WebSocket frame.
    ///
    /// - Throws: ``WebSocketServerError/connectionClosed`` if the channel is
    ///   inactive, or ``WebSocketServerError/encodingError`` if JSON encoding fails.
    public func send(_ message: Outgoing) async throws {
        guard channel.isActive else {
            throw WebSocketServerError.connectionClosed
        }
        
        do {
            let data = try encoder.encode(message)
            let buffer = channel.allocator.buffer(bytes: data)
            let frame = WebSocketFrame(fin: true, opcode: .binary, data: buffer)
            
            try await channel.writeAndFlush(frame)
        } catch {
            logger.error("Failed to send message: \(error)")
            throw WebSocketServerError.encodingError
        }
    }
    
    /// Send a close frame and tear the channel down. Safe to call multiple times.
    public func close() async {
        guard channel.isActive else { return }
        
        let frame = WebSocketFrame(fin: true, opcode: .connectionClose, data: ByteBuffer())
        try? await channel.writeAndFlush(frame)
        try? await channel.close()
        
        messageStreamContinuation.finish()
    }
    
    internal func handleFrame(_ frame: WebSocketFrame) async {
        logger.debug("Received frame - opcode: \(frame.opcode), fin: \(frame.fin), data length: \(frame.unmaskedData.readableBytes)")
        
        switch frame.opcode {
        case .binary:
            await handleBinaryFrame(frame)
        case .text:
            await handleTextFrame(frame)
        case .connectionClose:
            await handleCloseFrame()
        case .ping:
            await handlePingFrame(frame)
        case .pong:
            logger.debug("Received pong frame")
        case .continuation:
            await handleContinuationFrame(frame)
        default:
            logger.warning("Received unsupported frame type: \(frame.opcode)")
        }
    }
    
    private func handleBinaryFrame(_ frame: WebSocketFrame) async {
        let unmaskedData = frame.unmaskedData
        
        guard unmaskedData.readableBytes > 0 else {
            logger.warning("Received empty binary frame")
            return
        }
        
        let frameData = Data(unmaskedData.readableBytesView)
        
        if frame.fin {
            // Complete message (single frame or final frame)
            let completeData: Data
            if isReceivingFragmentedMessage {
                // Final frame of fragmented message
                completeData = partialBinaryMessage + frameData
                partialBinaryMessage = Data()
                isReceivingFragmentedMessage = false
            } else {
                // Single complete frame
                completeData = frameData
            }
            
            do {
                let message = try decoder.decode(Incoming.self, from: completeData)
                messageStreamContinuation.yield(message)
                await server.handleIncomingMessage(message, from: self)
            } catch {
                logger.error("Failed to decode binary message: \(error)")
            }
        } else {
            // First frame of fragmented message
            partialBinaryMessage = frameData
            isReceivingFragmentedMessage = true
        }
    }
    
    private func handleTextFrame(_ frame: WebSocketFrame) async {
        var unmaskedData = frame.unmaskedData
        
        guard unmaskedData.readableBytes > 0 else {
            logger.warning("Received empty text frame")
            return
        }
        
        guard let frameText = unmaskedData.readString(length: unmaskedData.readableBytes) else {
            logger.error("Failed to decode text frame as UTF-8 string")
            return
        }
        
        logger.debug("Text frame - fin: \(frame.fin), frame length: \(frameText.count), fragmented: \(isReceivingFragmentedMessage)")
        
        if frame.fin {
            // Complete message (single frame or final frame)
            let completeText: String
            if isReceivingFragmentedMessage {
                // Final frame of fragmented message
                completeText = partialTextMessage + frameText
                partialTextMessage = ""
                isReceivingFragmentedMessage = false
                logger.debug("Reassembled fragmented message, total length: \(completeText.count)")
            } else {
                // Single complete frame
                completeText = frameText
                logger.debug("Single complete frame, length: \(completeText.count)")
            }
            
            await processJSONText(completeText)
        } else {
            // First frame of fragmented message
            partialTextMessage = frameText
            isReceivingFragmentedMessage = true
            logger.debug("Started fragmented message, partial length: \(partialTextMessage.count)")
        }
    }
    
    private func processJSONText(_ text: String) async {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.hasPrefix("{") || trimmedText.hasPrefix("[") else {
            logger.info("Received non-JSON text message")
            return
        }
        
        do {
            let messageData = Data(text.utf8)
            logger.debug("Processing JSON message of size: \(messageData.count) bytes")
            let message = try decoder.decode(Incoming.self, from: messageData)
            messageStreamContinuation.yield(message)
            await server.handleIncomingMessage(message, from: self)
        } catch {
            logger.error("Failed to decode JSON message: \(error)")
            logger.error("Message size: \(text.utf8.count) bytes")
            logger.error("Message preview: \(String(text.prefix(200)))")
        }
    }
    
    private func handleContinuationFrame(_ frame: WebSocketFrame) async {
        guard isReceivingFragmentedMessage else {
            logger.warning("Received continuation frame without initial frame")
            return
        }
        
        var unmaskedData = frame.unmaskedData
        
        guard unmaskedData.readableBytes > 0 else {
            logger.warning("Received empty continuation frame")
            return
        }
        
        // Determine if this is text or binary continuation based on existing partial data
        if !partialTextMessage.isEmpty {
            // Text continuation
            guard let frameText = unmaskedData.readString(length: unmaskedData.readableBytes) else {
                logger.error("Failed to decode continuation frame as UTF-8 string")
                return
            }
            
            partialTextMessage += frameText
            
            if frame.fin {
                // Final continuation frame
                await processJSONText(partialTextMessage)
                partialTextMessage = ""
                isReceivingFragmentedMessage = false
            }
        } else {
            // Binary continuation
            let frameData = Data(unmaskedData.readableBytesView)
            partialBinaryMessage += frameData
            
            if frame.fin {
                // Final continuation frame
                do {
                    let message = try decoder.decode(Incoming.self, from: partialBinaryMessage)
                    messageStreamContinuation.yield(message)
                    await server.handleIncomingMessage(message, from: self)
                } catch {
                    logger.error("Failed to decode binary message: \(error)")
                }
                partialBinaryMessage = Data()
                isReceivingFragmentedMessage = false
            }
        }
    }
    
    private func handleCloseFrame() async {
        logger.info("Received close frame")
        await close()
    }
    
    private func handlePingFrame(_ frame: WebSocketFrame) async {
        guard channel.isActive else { return }

        // A pong MUST echo the ping's *application* payload. Client→server frames
        // are masked on the wire, so reply with the unmasked bytes — sending the
        // raw masked `frame.data` produces a payload mismatch that the `websockets`
        // client treats as an unsolicited pong, so its keep-alive ping times out
        // and it drops the connection every ~ping_interval+ping_timeout (~40s).
        let pongFrame = WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)
        try? await channel.writeAndFlush(pongFrame)
    }
    
    /// Send a WebSocket ping frame. Used for keep-alive checks.
    public func sendPing() async throws {
        guard channel.isActive else {
            throw WebSocketServerError.connectionClosed
        }
        
        let pingFrame = WebSocketFrame(fin: true, opcode: .ping, data: ByteBuffer())
        try await channel.writeAndFlush(pingFrame)
    }
}
