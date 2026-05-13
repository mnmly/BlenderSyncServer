/// # BlenderSyncServer
///
/// Receives messages from the `bl_camera_sync` Blender addon over WebSocket
/// and re-publishes them as strongly-typed ``BlenderMessage`` values on a
/// multi-subscriber `AsyncStream`.
///
/// ## Wire format
/// Messages arriving from the addon are JSON of the form:
/// ```json
/// { "type": "<snake_case>", "payload": { ... }, "timestamp": <epoch_seconds> }
/// ```
///
/// Supported `type` values:
/// - `"camera_update"` → ``BlenderMessage/cameraSnapshot(_:)``
/// - `"camera_curves"` → ``BlenderMessage/cameraCurves(_:)``
/// - `"scene_update"`  → ``BlenderMessage/sceneInfo(_:)``
///
/// Unknown types are surfaced as ``BlenderMessage/unknown(type:)`` rather
/// than dropped, so future addon additions don't silently disappear.

import Foundation
import Logging

// MARK: - Message

/// A decoded message from the Blender addon.
///
/// Each case wraps the strongly-typed payload corresponding to one of the
/// addon's `type` strings. Use ``typeString`` to recover the wire tag.
public enum BlenderMessage: Sendable {
    /// A live per-frame camera state (`camera_update`).
    case cameraSnapshot(CameraSnapshot)
    /// A batch of camera animation curves (`camera_curves`).
    case cameraCurves(CameraCurves)
    /// Scene-level render and frame range info (`scene_update`).
    case sceneInfo(SceneInfo)
    /// A message whose `type` is not recognized by this version of the server.
    case unknown(type: String)

    /// The wire `type` string corresponding to this message.
    public var typeString: String {
        switch self {
        case .cameraSnapshot: return "camera_update"
        case .cameraCurves:   return "camera_curves"
        case .sceneInfo:      return "scene_update"
        case .unknown(let t): return t
        }
    }
}

extension BlenderMessage: Codable {
    private enum Keys: String, CodingKey { case type, payload, timestamp }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "camera_update":
            self = .cameraSnapshot(try c.decode(CameraSnapshot.self, forKey: .payload))
        case "camera_curves":
            self = .cameraCurves(try c.decode(CameraCurves.self, forKey: .payload))
        case "scene_update":
            self = .sceneInfo(try c.decode(SceneInfo.self, forKey: .payload))
        default:
            self = .unknown(type: type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(typeString, forKey: .type)
        try c.encode(Date().timeIntervalSince1970, forKey: .timestamp)
        switch self {
        case .cameraSnapshot(let v): try c.encode(v, forKey: .payload)
        case .cameraCurves(let v):   try c.encode(v, forKey: .payload)
        case .sceneInfo(let v):      try c.encode(v, forKey: .payload)
        case .unknown:               break
        }
    }
}

// MARK: - Latest cache

/// Last-seen value of each message kind. Returned from `latestState()` so a
/// late subscriber can prime itself without waiting for the next message.
public struct BlenderLatestState: Sendable {
    public var cameraSnapshot: CameraSnapshot?
    public var cameraCurves: CameraCurves?
    public var sceneInfo: SceneInfo?
}

// MARK: - Server

/// Actor that hosts a WebSocket endpoint, decodes Blender addon messages, and
/// fans them out to subscribers.
///
/// Lifecycle:
/// 1. Create with ``init(host:port:logger:)``.
/// 2. Call ``start()`` to bind the socket.
/// 3. Subscribe via ``messages(bufferSize:)`` from one or more tasks.
/// 4. Call ``stop()`` to shut down.
public actor BlenderSyncServer {
    private let baseServer: WebSocketServer<BlenderMessage, BlenderMessage>
    private let logger: Logger

    private var subscribers: [UUID: AsyncStream<BlenderMessage>.Continuation] = [:]
    private var latest = BlenderLatestState()
    private var started = false

    /// Create a server bound to the given host/port.
    ///
    /// - Parameters:
    ///   - host: Interface to bind. Defaults to loopback.
    ///   - port: TCP port. Defaults to `8765` — the same default the Blender addon uses.
    ///   - logger: swift-log logger used for status and error messages.
    public init(
        host: String = "127.0.0.1",
        port: Int = 8765,
        logger: Logger = Logger(label: "BlenderSyncServer")
    ) {
        self.logger = logger

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        self.baseServer = WebSocketServer(
            host: host, port: port, logger: logger,
            encoder: encoder, decoder: decoder
        )
    }

    /// Bind the WebSocket and begin accepting connections from the Blender addon.
    ///
    /// Idempotent: subsequent calls while already running are no-ops.
    /// Throws ``WebSocketServerError/bindingFailed`` if the host/port cannot be bound.
    public func start() async throws {
        guard !started else { return }
        // Wire the handler before binding, so no message can arrive before we
        // route it. (The previous design did this in a free Task and lost the
        // race for fast-connecting clients.)
        await baseServer.setMessageHandler { [weak self] message, _ in
            await self?.dispatch(message)
        }
        try await baseServer.start()
        started = true
    }

    /// Close all client connections, finish every subscriber's stream, and
    /// shut the listener down. Idempotent.
    public func stop() async {
        guard started else { return }
        await baseServer.stop()
        for (_, c) in subscribers { c.finish() }
        subscribers.removeAll()
        started = false
    }

    /// Subscribe to the live message stream.
    ///
    /// Each subscriber gets its own `AsyncStream` with newest-buffering — slow
    /// consumers drop old frames rather than backing up the WebSocket pipeline.
    /// The stream finishes when ``stop()`` is called or the subscriber's task
    /// is cancelled.
    ///
    /// - Parameter bufferSize: Maximum messages buffered per subscriber.
    /// - Returns: An `AsyncStream` of decoded ``BlenderMessage`` values.
    public func messages(bufferSize: Int = 8) -> AsyncStream<BlenderMessage> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<BlenderMessage>.makeStream(
            bufferingPolicy: .bufferingNewest(bufferSize)
        )
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    /// Snapshot of the most recent value for each message kind. Useful for
    /// priming UI when a sketch loads after Blender already pushed state.
    public func latestState() -> BlenderLatestState { latest }

    // MARK: internal

    private func dispatch(_ message: BlenderMessage) {
        switch message {
        case .cameraSnapshot(let v): latest.cameraSnapshot = v
        case .cameraCurves(let v):   latest.cameraCurves = v
        case .sceneInfo(let v):      latest.sceneInfo = v
        case .unknown(let t):        logger.debug("unknown message type: \(t)")
        }
        for (_, c) in subscribers { c.yield(message) }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }
}
