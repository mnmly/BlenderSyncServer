# BlenderSyncServer API

Auto-generated from source comments by `scripts/generate_api_docs.py`.
Edit the source doc comments, not this file.

---

# Swift package

## `Sources/BlenderSyncServer/BlenderSyncServer.swift`

### Overview

# BlenderSyncServer

Receives messages from the `bl_camera_sync` Blender addon over WebSocket
and re-publishes them as strongly-typed ``BlenderMessage`` values on a
multi-subscriber `AsyncStream`.

## Wire format
Messages arriving from the addon are JSON of the form:
```json
{ "type": "<snake_case>", "payload": { ... }, "timestamp": <epoch_seconds> }
```

Supported `type` values:
- `"camera_update"` → ``BlenderMessage/cameraSnapshot(_:)``
- `"camera_curves"` → ``BlenderMessage/cameraCurves(_:)``
- `"scene_update"`  → ``BlenderMessage/sceneInfo(_:)``

Unknown types are surfaced as ``BlenderMessage/unknown(type:)`` rather
than dropped, so future addon additions don't silently disappear.

### Enum — `public enum BlenderMessage: Sendable`

A decoded message from the Blender addon.

Each case wraps the strongly-typed payload corresponding to one of the
addon's `type` strings. Use ``typeString`` to recover the wire tag.

### Property — `public var typeString: String`

The wire `type` string corresponding to this message.

### Struct — `public struct BlenderLatestState: Sendable`

Last-seen value of each message kind. Returned from `latestState()` so a
late subscriber can prime itself without waiting for the next message.

### Actor — `public actor BlenderSyncServer`

Actor that hosts a WebSocket endpoint, decodes Blender addon messages, and
fans them out to subscribers.

Lifecycle:
1. Create with ``init(host:port:logger:)``.
2. Call ``start()`` to bind the socket.
3. Subscribe via ``messages(bufferSize:)`` from one or more tasks.
4. Call ``stop()`` to shut down.

### Initializer — `public init( host: String = "127.0.0.1", port: Int = 8765, logger: Logger = Logger(label: "BlenderSyncServer") )`

Create a server bound to the given host/port.

- Parameters:
- host: Interface to bind. Defaults to loopback.
- port: TCP port. Defaults to `8765` — the same default the Blender addon uses.
- logger: swift-log logger used for status and error messages.

### Function — `public func start() async throws`

Bind the WebSocket and begin accepting connections from the Blender addon.

Idempotent: subsequent calls while already running are no-ops.
Throws ``WebSocketServerError/bindingFailed`` if the host/port cannot be bound.

### Function — `public func stop() async`

Close all client connections, finish every subscriber's stream, and
shut the listener down. Idempotent.

### Function — `public func messages(bufferSize: Int = 8) -> AsyncStream<BlenderMessage>`

Subscribe to the live message stream.

Each subscriber gets its own `AsyncStream` with newest-buffering — slow
consumers drop old frames rather than backing up the WebSocket pipeline.
The stream finishes when ``stop()`` is called or the subscriber's task
is cancelled.

- Parameter bufferSize: Maximum messages buffered per subscriber.
- Returns: An `AsyncStream` of decoded ``BlenderMessage`` values.

### Function — `public func latestState() -> BlenderLatestState`

Snapshot of the most recent value for each message kind. Useful for
priming UI when a sketch loads after Blender already pushed state.


## `Sources/BlenderSyncServer/CameraCurves.swift`

### Overview

Camera animation curves received from the Blender addon (`camera_curves`).

The evaluator below is a faithful port of Blender's `evaluate_fcurve` /
`fcurve_eval_keyframes_interpolate` / `fcurve_eval_keyframes_extrapolate`
from `source/blender/blenkernel/intern/fcurve.cc`, plus the easing functions
from `source/blender/blenlib/intern/easing.cc` (Robert Penner's set, as used
by Blender). Animation modifiers and drivers are not supported.

Coordinate conventions: keyframe `frame` is in Blender frames; handle `x/y`
are in absolute `(frame, value)` space, not deltas.

### Struct — `public struct CameraCurves: Codable, Sendable`

All animation data needed to reproduce a Blender camera's motion offline.

Combines a `static` snapshot of every camera property at `frameStart` with
the raw fcurves so consumers can evaluate the camera at any frame without
a Blender runtime.

### Property — `public let name: String`

Camera object name.

### Property — `public let frameStart: Int`

Inclusive timeline start frame.

### Property — `public let frameEnd: Int`

Inclusive timeline end frame.

### Property — `public let fps: Double`

Scene frame rate (`fps / fps_base`).

### Property — `public let renderWidth: Int`

Render width in pixels.

### Property — `public let renderHeight: Int`

Render height in pixels.

### Property — `public let renderAspect: Double`

Render aspect ratio.

### Property — `public let `static`: CameraStatic`

Snapshot of all camera properties at `frameStart`.

Used as the fallback value for any property that isn't animated.

### Property — `public let fcurves: [FCurve]`

Every fcurve found on the camera object and its data block.

### Initializer — `public init(name: String, frameStart: Int, frameEnd: Int, fps: Double, renderWidth: Int, renderHeight: Int, renderAspect: Double, static staticVals: CameraStatic, fcurves: [FCurve])`

Memberwise initializer.

### Function — `public static func decode(from data: Data) throws -> CameraCurves`

Convenience decoder configured with `convertFromSnakeCase`.

### Function — `public func fcurve(source: String, dataPath: String, arrayIndex: Int = 0) -> FCurve?`

Look up an fcurve by source + data_path + array_index. Returns nil if absent.

### Function — `public func sample(at frame: Double) -> CameraSample`

Compose camera state at the given frame.

Pose is built as T·R·S from animated `location`, `rotation_euler`,
`scale` fcurves on the camera object (each axis falls back to the
`static` value if not animated). Intrinsics come from the animated
`lens`/`clip_start`/`clip_end`/etc. on the camera data block.

Limitation: this composition only sees keyed values on the camera
itself. Parent transforms, drivers, and constraints are NOT applied.
For accurate world-space pose under those conditions, use the
`bakedKeyframes` on `CameraSnapshot` instead (which Blender evaluates
against the depsgraph).

### Struct — `public struct CameraSample: Sendable`

Camera state evaluated at a single (possibly fractional) frame.

Returned by ``CameraCurves/sample(at:)``. Pose is composed from animated
fcurves only; parents, drivers, and constraints are not honored — see the
note on ``CameraCurves/sample(at:)``.

### Property — `public let frame: Double`

Evaluated frame (may be fractional).

### Property — `public let location: SIMD3<Double>`

World-space location.

### Property — `public let rotationEuler: SIMD3<Double>`

Euler rotation in radians, XYZ order (Blender default `rotation_mode`).

### Property — `public let scale: SIMD3<Double>`

Per-axis scale.

### Property — `public let matrixWorld: simd_double4x4`

Pose composed as `T · R(XYZ) · S` — see ``CameraCurves/sample(at:)`` limitations.

### Property — `public let focalLength: Double`

Focal length in millimeters.

### Property — `public let sensorWidth: Double`

Sensor width in millimeters.

### Property — `public let sensorHeight: Double`

Sensor height in millimeters.

### Property — `public let verticalFov: Double`

Vertical FOV in degrees.

### Property — `public let clipStart: Double`

Near clip distance.

### Property — `public let clipEnd: Double`

Far clip distance.

### Property — `public var matrixWorldMatrix: simd_double4x4`

`matrix_world` reassembled as a `simd_double4x4`.

The wire form is row-major (Blender `Matrix` iteration yields rows);
this transposes into simd's column-major convention.

### Struct — `public struct CameraStatic: Codable, Sendable`

Snapshot of every camera property at `frameStart`.

Provides fallback values for properties that aren't animated, plus the
`sensorFit` mode needed to recompute vertical FOV as intrinsics change.

### Property — `public let matrixWorld: [Double]`

16-float row-major world matrix at `frameStart`.

### Property — `public let location: [Double]`

Location at `frameStart` (`[x, y, z]`).

### Property — `public let rotationEuler: [Double]`

Euler rotation at `frameStart` in radians, XYZ order.

### Property — `public let scale: [Double]`

Scale at `frameStart` (`[x, y, z]`).

### Property — `public let focalLength: Double`

Focal length in millimeters.

### Property — `public let sensorWidth: Double`

Sensor width in millimeters.

### Property — `public let sensorHeight: Double`

Sensor height in millimeters.

### Property — `public let sensorFit: String`

Blender's `sensor_fit`: `"AUTO"`, `"HORIZONTAL"`, or `"VERTICAL"`.

### Property — `public let clipStart: Double`

Near clip distance.

### Property — `public let clipEnd: Double`

Far clip distance.

### Property — `public let verticalFov: Double`

Vertical FOV in degrees at `frameStart`.

### Struct — `public struct FCurve: Codable, Sendable`

A single Blender F-Curve: an animation channel targeting one scalar property.

### Property — `public let source: String`

Owner tag: `"object"` (transform/visibility) or `"data"` (lens/sensor/clip).

Modifier and constraint animations are folded onto the object's action,
so they appear here with `source == "object"` and a `data_path` like
`constraints["TrackTo"].influence`.

### Property — `public let dataPath: String`

RNA data path of the animated property (e.g. `"location"`, `"lens"`).

### Property — `public let arrayIndex: Int`

Index into the animated property when it's vector-valued (0 = x, etc.).

### Property — `public let extrapolation: Extrapolation`

What to do outside the keyframe range.

### Property — `public let hasModifiers: Bool`

`true` if Blender reports animation modifiers on this curve.

Modifiers (noise, cycles, …) are NOT replayed by ``evaluate(at:)`` —
only the underlying keyframes are. Use baked keyframes for fidelity.

### Property — `public let keyframes: [Keyframe]`

Keyframes in frame order.

### Initializer — `public init(source: String, dataPath: String, arrayIndex: Int, extrapolation: Extrapolation, hasModifiers: Bool, keyframes: [Keyframe])`

Memberwise initializer.

### Struct — `public struct Keyframe: Codable, Sendable`

One keyframe in an ``FCurve``.

Stores both the value and the per-keyframe interpolation/easing settings
that govern the segment *leading out of* this keyframe.

### Property — `public let frame: Double`

X coordinate of the keyframe (Blender frame number, fractional allowed).

### Property — `public let value: Double`

Y coordinate of the keyframe (the animated value).

### Property — `public let interpolation: Interpolation`

Interpolation type applied to the segment after this keyframe.

### Property — `public let easing: Easing`

Easing direction (`AUTO` / `EASE_IN` / `EASE_OUT` / `EASE_IN_OUT`).

### Property — `public let handleLeft: [Double]`

Left Bezier handle in absolute `(frame, value)` space.

### Property — `public let handleRight: [Double]`

Right Bezier handle in absolute `(frame, value)` space.

### Property — `public let amplitude: Double`

Amplitude parameter for `ELASTIC` interpolation.

### Property — `public let period: Double`

Period parameter for `ELASTIC` interpolation.

### Property — `public let back: Double`

Overshoot parameter for `BACK` interpolation.

### Initializer — `public init(frame: Double, value: Double, interpolation: Interpolation, easing: Easing, handleLeft: [Double], handleRight: [Double], amplitude: Double = 0, period: Double = 0, back: Double = 1.70158)`

Memberwise initializer. `back` defaults to Blender's value of `1.70158`.

### Enum — `public enum Interpolation: String, Codable, Sendable`

Per-keyframe interpolation mode. Mirrors Blender's `keyframe.interpolation`.

### Enum — `public enum Easing: String, Codable, Sendable`

Easing direction for non-Bezier interpolations. Mirrors Blender's `keyframe.easing`.

### Enum — `public enum Extrapolation: String, Codable, Sendable`

How the curve behaves outside its keyframe range.
Mirrors Blender's `fcurve.extrapolation`.

### Function — `public func evaluate(at frame: Double) -> Double`

Evaluate the curve at a frame. Mirrors Blender's `evaluate_fcurve`.


## `Sources/BlenderSyncServer/CameraSnapshot.swift`

### Overview

Live per-frame camera state sent by the Blender addon as `camera_update`.

Mirrors the dict produced by `snapshot_camera()` in the addon. Snake-case
wire fields are mapped to camelCase via
`JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase`, configured by
``BlenderSyncServer``.

### Struct — `public struct CameraSnapshot: Sendable, Codable`

One frame of evaluated camera state from Blender.

Includes pose (location/rotation/scale + world matrix), intrinsics
(focal length, sensor, FOV, clip), render dimensions, the current frame,
and an optional sequence of pre-baked world matrices over the timeline.

### Property — `public let name: String`

Blender object name (`bpy.types.Object.name`).

### Property — `public let location: SIMD3<Double>`

World-space camera location in Blender units (meters by default).

### Property — `public let rotationEuler: SIMD3<Double>`

Euler rotation in radians, XYZ order — Blender's default `rotation_mode`.

### Property — `public let quaternion: SIMD4<Double>`

Quaternion in `(w, x, y, z)` order — matches Blender's `mathutils.Quaternion`.

### Property — `public let scale: SIMD3<Double>`

Per-axis scale factor.

### Property — `public let matrixWorld: simd_double4x4`

Evaluated world matrix — composed from the wire's 16-float row-major array
and stored as a column-major `simd_double4x4`.

### Property — `public let focalLength: Double`

Focal length in millimeters (`camera.data.lens`).

### Property — `public let sensorWidth: Double`

Sensor width in millimeters (`camera.data.sensor_width`).

### Property — `public let sensorHeight: Double`

Sensor height in millimeters (`camera.data.sensor_height`).

### Property — `public let verticalFov: Double`

Vertical field of view in degrees, computed via Blender's `sensor_fit` logic.

### Property — `public let clipStart: Double`

Near clip distance in Blender units.

### Property — `public let clipEnd: Double`

Far clip distance in Blender units.

### Property — `public let renderWidth: Int`

Render output width in pixels.

### Property — `public let renderHeight: Int`

Render output height in pixels.

### Property — `public let renderAspect: Double`

Render aspect ratio (`renderWidth / renderHeight`).

### Property — `public let frame: Int`

Current playhead frame at the moment of the snapshot.

### Property — `public let bakedKeyframes: [BakedKeyframe]`

Optional pre-baked world matrices, one per requested frame.

When the addon is asked to include keyframes, it evaluates the camera
against the depsgraph at each frame in the timeline (or only at frames
containing explicit keyframes when `send_only_explicit_keyframes` is on).
This is the only safe source of truth for cameras driven by parents,
constraints, or drivers.

### Struct — `public struct BakedKeyframe: Sendable, Codable`

A single baked frame: `(frame, world_matrix)` from the evaluated depsgraph.

### Property — `public let frame: Int`

Blender frame number.

### Property — `public let matrixWorld: simd_double4x4`

Evaluated world matrix at that frame.

### Initializer — `public init(frame: Int, matrixWorld: simd_double4x4)`

Memberwise initializer.


## `Sources/BlenderSyncServer/SceneInfo.swift`

### Overview

Scene-level render and timeline metadata sent by the addon as `scene_update`.

Mirrors the dict produced by `snapshot_scene()` in the Blender addon.

### Struct — `public struct SceneInfo: Sendable, Codable`

Render resolution and frame-range info for the active Blender scene.

### Property — `public let resolutionWidth: Int`

Render resolution width in pixels (`scene.render.resolution_x`).

### Property — `public let resolutionHeight: Int`

Render resolution height in pixels (`scene.render.resolution_y`).

### Property — `public let frameRate: Double`

Effective frame rate (`fps / fps_base`).

### Property — `public let frameStart: Int`

Inclusive timeline start (`scene.frame_start`).

### Property — `public let frameEnd: Int`

Inclusive timeline end (`scene.frame_end`).

### Property — `public let frameCurrent: Int`

Current playhead frame at the moment of snapshot (`scene.frame_current`).

### Initializer — `public init(resolutionWidth: Int, resolutionHeight: Int, frameRate: Double, frameStart: Int, frameEnd: Int, frameCurrent: Int)`

Memberwise initializer.


## `Sources/BlenderSyncServer/WebSocketConnection.swift`

### Overview

A single client WebSocket connection owned by ``WebSocketServer``.

Handles fragmentation, JSON decoding, and ping/pong. Inbound messages are
surfaced both through ``messageStream`` (per-connection) and through the
server's installed message handler.

### Class — `public final class WebSocketConnection<Incoming: Codable & Sendable, Outgoing: Codable & Sendable>: Sendable`

An upgraded WebSocket connection managed by ``WebSocketServer``.

### Property — `public let messageStream: AsyncThrowingStream<Incoming, Error>`

Per-connection async stream of decoded inbound messages.

Finishes when the connection closes. Yields the same values that are
dispatched to the server's installed message handler.

### Function — `public func send(_ message: Outgoing) async throws`

Send a single message as a binary WebSocket frame.

- Throws: ``WebSocketServerError/connectionClosed`` if the channel is
inactive, or ``WebSocketServerError/encodingError`` if JSON encoding fails.

### Function — `public func close() async`

Send a close frame and tear the channel down. Safe to call multiple times.

### Function — `public func sendPing() async throws`

Send a WebSocket ping frame. Used for keep-alive checks.


## `Sources/BlenderSyncServer/WebSocketServer.swift`

### Overview

Generic WebSocket server actor used by ``BlenderSyncServer``.

Hosts an HTTP listener that upgrades `/ws` requests to WebSocket, JSON-decodes
incoming frames into the generic `Incoming` type, and JSON-encodes outgoing
`Outgoing` values. Connection lifetimes and broadcasts are managed for you.

### Enum — `public enum WebSocketServerError: Error`

Errors thrown by ``WebSocketServer`` and ``WebSocketConnection``.

### Actor — `public actor WebSocketServer<Incoming: Codable & Sendable, Outgoing: Codable & Sendable>`

Generic actor-based WebSocket server.

`Incoming` is the message type decoded from inbound frames; `Outgoing` is
the type encoded to outbound frames. Both must be `Codable & Sendable`.

### Initializer — `public init( host: String = "127.0.0.1", port: Int = 8080, logger: Logger = Logger(label: "WebSocketServer"), encoder: JSONEncoder = JSONEncoder(), decoder: JSONDecoder = JSONDecoder() )`

Create a server bound to `host:port`.

- Parameters:
- host: Interface to bind. Defaults to loopback.
- port: TCP port.
- logger: swift-log logger.
- encoder: JSON encoder used for outgoing frames.
- decoder: JSON decoder used for incoming frames.

### Function — `public func start() async throws`

Bind the socket and start accepting WebSocket upgrades on `/ws`.

Throws ``WebSocketServerError/bindingFailed`` if the host/port cannot be bound.

### Function — `public func stop() async`

Close all active connections and shut the listener down gracefully.

### Function — `public func broadcast(_ message: Outgoing) async throws`

Send `message` to every currently-connected client concurrently.

Per-connection send failures are logged and do not throw — one slow or
broken client cannot block delivery to others.

### Function — `public func setMessageHandler(_ handler: @escaping @Sendable (Incoming, WebSocketConnection<Incoming, Outgoing>) async -> Void)`

Install a closure invoked for every successfully decoded inbound message.

The handler runs on the server actor. Replace at any time; only the most
recently installed handler is called.


---

# Blender addon (`bl_camera_sync`)

## `blender-addon/bl_camera_sync/__init__.py`

### Overview

bl_camera_sync — Blender addon that streams the active camera over WebSocket.

The addon snapshots the active camera (pose + intrinsics, optionally with
baked depsgraph-evaluated keyframes) and ships JSON messages to a server such
as the companion `BlenderSyncServer` Swift package.

Wire protocol
-------------
All outbound messages share the envelope::

    { "type": "<snake_case>", "payload": { ... }, "timestamp": <float> }

Supported `type` values:

* ``camera_update``  — payload from :func:`snapshot_camera`
* ``camera_curves``  — payload from :func:`snapshot_camera_curves`
* ``scene_update``   — payload from :func:`snapshot_scene`

Threading model
---------------
All ``bpy.*`` access happens on Blender's main thread. The websocket lives on
a background asyncio loop; the two communicate via an ``asyncio.Queue``
(outbound) and ``bpy.app.timers`` callbacks (inbound). Do not call any
``snapshot_*`` function from a non-main thread.

### Class — `class CameraSyncProperties`

Scene-level UI properties for the Camera Sync panel.

Registered as ``Scene.camera_sync_props``. Holds the websocket target,
connection status, and sync behavior flags toggled from the N-panel.

Attributes:
    host: Hostname or IP of the sync server.
    port: TCP port (default 8765).
    is_connected: Read-only; updated by :class:`CameraSyncManager`.
    auto_sync: If True, push live camera snapshots at ``sync_rate``.
    sync_keyframes: If True, include the baked keyframe matrix list in
        manual sends.
    auto_reconnect: If True, retry the connection with exponential backoff
        after a drop.
    sync_rate: Target send frequency in Hz when ``auto_sync`` is on.
    send_only_explicit_keyframes: When baking keyframes, only sample frames
        that actually contain a keyframe (rather than the full range).

### Function — `def snapshot_camera(with_baked_keyframes, explicit_only)`

Capture the active camera's evaluated pose and intrinsics.

Must be called on Blender's main thread (touches ``bpy.*``).

Args:
    with_baked_keyframes: If True, also evaluate the camera at every frame
        in ``[scene.frame_start, scene.frame_end]`` and include the
        resulting world matrices in ``baked_keyframes``. Honors parent
        transforms, constraints, and drivers (unlike fcurve sampling).
    explicit_only: If True (and ``with_baked_keyframes`` is True), bake only
        frames containing explicit keyframes instead of the full range.

Returns:
    dict | None: ``camera_update`` payload, or ``None`` if no active camera
    or the active object is not a camera. Schema:

    * ``name`` (str)
    * ``location`` ([x, y, z]), ``rotation`` (Euler XYZ radians),
      ``quaternion`` ([w, x, y, z]), ``scale`` ([x, y, z])
    * ``matrix_world`` (16 floats, row-major)
    * ``focal_length`` (mm), ``sensor_width``, ``sensor_height``,
      ``vertical_fov`` (degrees)
    * ``render_width``, ``render_height``, ``render_aspect``
    * ``clip_start``, ``clip_end``
    * ``frame`` (current playhead frame)
    * ``baked_keyframes``: list of ``{frame, matrix_world}`` (may be empty)

### Function — `def snapshot_camera_curves()`

Capture the active camera's animation curves for offline replay.

Must be called on Blender's main thread. Iterates the camera object's
action and its data block's action, recording every fcurve's keyframes
plus the per-key interpolation/easing settings.

Animation modifiers (noise, cycles, etc.) are NOT exported — if a curve
has modifiers, its keyframes are still sent but the Python-side baked
output will differ. Drivers are skipped entirely.

Returns:
    dict | None: ``camera_curves`` payload, or ``None`` if no active
    camera. Includes a ``static`` block (every property at
    ``frame_start``) and an ``fcurves`` list. See the
    :class:`CameraCurves` Swift struct for the field-by-field schema.

### Function — `def snapshot_scene()`

Capture scene-level render and timeline settings.

Must be called on Blender's main thread.

Returns:
    dict: ``scene_update`` payload with ``resolution_width``,
    ``resolution_height``, ``frame_rate`` (``fps / fps_base``),
    ``frame_start``, ``frame_end``, and ``frame_current``.

### Class — `class CameraSyncManager`

Owns the websocket connection and bridges Blender's main thread to asyncio.

Lifecycle:
    * :meth:`start_connection` spins up a background thread running an
      asyncio loop, then registers a main-thread timer that snapshots the
      camera at the configured rate.
    * :meth:`enqueue` is thread-safe and posts a message onto the loop's
      ``asyncio.Queue``.
    * :meth:`stop_connection` flips ``is_running`` to False and joins the
      background thread.

Only the coroutine running on the loop touches the websocket; all
``bpy.*`` access is marshalled through ``bpy.app.timers``.

### Function — `def CameraSyncManager.set_connected_main_thread(self, value)`

Schedule a property write on the main thread.

### Function — `def CameraSyncManager.enqueue(self, message)`

Push an outgoing message to the websocket coroutine. Thread-safe.

### Function — `def CameraSyncManager.start_connection(self, host, port)`

Spawn the asyncio thread and main-thread snapshot timer.

No-op if already running.

### Function — `def CameraSyncManager.stop_connection(self)`

Stop the asyncio loop and join the background thread (1s timeout).

### Class — `class CAMERA_SYNC_OT_connect`

Operator: open a websocket to the configured ``host:port``.

### Class — `class CAMERA_SYNC_OT_disconnect`

Operator: tear down the active websocket connection.

### Class — `class CAMERA_SYNC_OT_send_manual`

Operator: snapshot the camera (with baked keyframes) and enqueue a ``camera_update``.

### Class — `class CAMERA_SYNC_OT_send_scene_info`

Operator: enqueue a one-shot ``scene_update`` message.

### Class — `class CAMERA_SYNC_OT_send_camera_curves`

Operator: extract raw f-curve data from the camera and enqueue ``camera_curves``.

### Class — `class CAMERA_SYNC_OT_test_connection`

Operator: TCP-probe ``host:port`` to confirm the sync server is reachable.

### Class — `class CAMERA_SYNC_PT_panel`

N-panel UI under the "Camera Sync" tab in the 3D View.

### Function — `def register()`

Register operators, panel, and the scene-level ``camera_sync_props`` pointer.

Called automatically by Blender when the addon is enabled.

### Function — `def unregister()`

Tear down the websocket connection and undo :func:`register`.


## `blender-addon/bl_camera_sync/utils.py`

### Overview

Helpers for installing third-party Python packages into Blender's user modules dir.

Blender ships its own embedded Python and isolates its `site-packages` from
the system interpreter. This module locates a writable user scripts directory,
appends it to ``sys.path``, and pip-installs missing packages there so the
addon can `import websockets` without admin rights.

### Function — `def get_blender_python_path()`

Returns the path of Blender's embedded Python interpreter.

### Function — `def get_modules_path()`

Return a writable directory for installing Python packages.

### Function — `def append_modules_to_sys_path(modules_path)`

Ensure Blender can find installed packages.

### Function — `def display_message(message, title, icon)`

Show a popup message in Blender.

### Function — `def install_package(package, modules_path)`

Install a single package using Blender's Python.

### Function — `def background_install_packages(packages, modules_path)`

Install missing packages in a background thread.
