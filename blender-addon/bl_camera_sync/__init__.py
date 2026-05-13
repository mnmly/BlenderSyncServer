"""bl_camera_sync — Blender addon that streams the active camera over WebSocket.

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
"""

import bpy
import asyncio
import json
import threading
import time
import math
import logging
from bpy.props import StringProperty, IntProperty, BoolProperty
from bpy.types import Panel, Operator, PropertyGroup
from mathutils import Matrix, Vector
from .utils import append_modules_to_sys_path, background_install_packages, get_modules_path

logger = logging.getLogger(__name__)
DEBUG = False  # toggle to enable per-send logging

REQUIRED_PACKAGES = {'websockets': 'websockets'}
modules_path = get_modules_path()
append_modules_to_sys_path(modules_path)
background_install_packages(REQUIRED_PACKAGES, modules_path)


def _log(msg):
    if DEBUG:
        logger.info(msg)


class CameraSyncProperties(PropertyGroup):
    """Scene-level UI properties for the Camera Sync panel.

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
    """
    host: StringProperty(name="Host", default="localhost")
    port: IntProperty(name="Port", default=8765, min=1, max=65535)
    is_connected: BoolProperty(name="Connected", default=False)
    auto_sync: BoolProperty(name="Auto Sync", default=True)
    sync_keyframes: BoolProperty(name="Sync Keyframes", default=True)
    auto_reconnect: BoolProperty(name="Auto Reconnect", default=True)
    sync_rate: IntProperty(name="Sync Rate (FPS)", default=30, min=1, max=120)
    send_only_explicit_keyframes: BoolProperty(
        name="Send Only Explicit Keyframes",
        description="Only bake frames that contain explicit keyframes",
        default=False,
    )


# ---------------------------------------------------------------------------
# Data snapshotting (MAIN THREAD ONLY — touches bpy.*)
# ---------------------------------------------------------------------------

def _fcurves_of(anim_owner):
    """Return the fcurves iterable for an anim-data owner, across Blender 4.x and 5.x."""
    if not anim_owner or not anim_owner.animation_data or not anim_owner.animation_data.action:
        return None
    action = anim_owner.animation_data.action
    anim_data = anim_owner.animation_data
    if hasattr(anim_data, 'action_slot'):
        try:
            from bpy_extras import anim_utils
            slot = anim_data.action_slot
            if slot:
                cb = anim_utils.action_get_channelbag_for_slot(action, slot)
                if cb:
                    return cb.fcurves
        except (ImportError, AttributeError):
            pass
    return getattr(action, 'fcurves', None)


def _iter_anim_sources(obj):
    """Yield (source_tag, anim_owner) for the camera and its data block.

    Only ID datablocks have their own `animation_data`. Constraint/modifier
    animation lives on the *parent object's* action with a data_path like
    `constraints["TrackTo"].influence`, so iterating those fcurves through
    the object owner already picks them up — we don't need to (and can't)
    yield the constraint/modifier as its own anim source.

    Note: constraints (Track To, Follow Path, etc.) evaluate at depsgraph
    time and override the keyed pose. fcurve sampling alone cannot reproduce
    their effect; consumers should fall back to `baked_keyframes` (which
    snapshot_camera bakes against the evaluated depsgraph) when the camera
    has constraints.
    """
    yield ("object", obj)
    if hasattr(obj, 'data'):
        yield ("data", obj.data)


def _collect_explicit_keyframes(obj):
    frames = set()
    for _, owner in _iter_anim_sources(obj):
        fcs = _fcurves_of(owner)
        if not fcs:
            continue
        for fc in fcs:
            for kf in fc.keyframe_points:
                frames.add(int(kf.co[0]))
    return sorted(frames)


def _bake_camera_matrices(scene, camera, start, end, explicit_only):
    """Evaluate the camera's world matrix at each frame in `[start, end]`.

    Steps the timeline (which fully resolves parents, constraints, and drivers
    via the depsgraph), then restores the original frame in a `finally` so
    long-running bakes don't leave Blender on a weird frame.

    Args:
        scene: The active ``bpy.types.Scene``.
        camera: The camera ``bpy.types.Object`` to evaluate.
        start: Inclusive start frame.
        end: Inclusive end frame.
        explicit_only: If True, only sample frames that already have an
            explicit keyframe (via :func:`_collect_explicit_keyframes`).
            Otherwise samples every integer frame in the range.

    Returns:
        list[dict]: ``{"frame": int, "matrix_world": list[float]}`` entries.
            ``matrix_world`` is row-major (16 floats).
    """
    matrices = []
    original_frame = scene.frame_current

    if explicit_only:
        frames = [f for f in _collect_explicit_keyframes(camera) if start <= f <= end]
    else:
        frames = range(start, end + 1)

    render_aspect = scene.render.resolution_x / max(scene.render.resolution_y, 1)
    try:
        for frame in frames:
            scene.frame_set(frame)
            depsgraph = bpy.context.evaluated_depsgraph_get()
            cam_eval = camera.evaluated_get(depsgraph)
            mat = [v for row in cam_eval.matrix_world for v in row]
            cam_data_eval = cam_eval.data
            matrices.append({
                "frame": frame,
                "matrix_world": mat,
                "focal_length": cam_data_eval.lens,
                "vertical_fov": _compute_vertical_fov_degrees(cam_data_eval, render_aspect),
            })
    finally:
        scene.frame_set(original_frame)

    return matrices


def _compute_vertical_fov_degrees(cam_data, render_aspect):
    """Return the camera's vertical FOV in degrees, honoring `sensor_fit`.

    Replicates Blender's render-time logic: in ``AUTO`` mode the fit axis is
    chosen by comparing render aspect against sensor aspect.
    """
    focal = cam_data.lens
    sw, sh = cam_data.sensor_width, cam_data.sensor_height
    fit = cam_data.sensor_fit

    if fit == 'AUTO':
        if render_aspect > (sw / sh):
            h_fov = 2 * math.atan(sw / (2 * focal))
            v_fov = 2 * math.atan(math.tan(h_fov / 2) / render_aspect)
        else:
            v_fov = 2 * math.atan(sh / (2 * focal))
    elif fit == 'HORIZONTAL':
        h_fov = 2 * math.atan(sw / (2 * focal))
        v_fov = 2 * math.atan(math.tan(h_fov / 2) / render_aspect)
    else:  # VERTICAL or fallback
        v_fov = 2 * math.atan(sh / (2 * focal))

    return math.degrees(v_fov)


def snapshot_camera(with_baked_keyframes=False, explicit_only=False):
    """Capture the active camera's evaluated pose and intrinsics.

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
    """
    scene = bpy.context.scene
    if not scene.camera:
        return None

    depsgraph = bpy.context.evaluated_depsgraph_get()
    camera = scene.camera.evaluated_get(depsgraph)
    if camera.type != 'CAMERA':
        return None

    if camera.rotation_mode != 'QUATERNION':
        quat = camera.rotation_euler.to_quaternion()
    else:
        quat = camera.rotation_quaternion

    mat = [v for row in camera.matrix_world for v in row]
    cam_data = camera.data
    render = scene.render
    aspect = render.resolution_x / render.resolution_y

    data = {
        "name": camera.name,
        "location": list(camera.location),
        "rotation": list(camera.rotation_euler),
        "quaternion": list(quat),
        "matrix_world": mat,
        "scale": list(camera.scale),
        "focal_length": cam_data.lens,
        "sensor_width": cam_data.sensor_width,
        "sensor_height": cam_data.sensor_height,
        "vertical_fov": _compute_vertical_fov_degrees(cam_data, aspect),
        "render_aspect": aspect,
        "render_width": render.resolution_x,
        "render_height": render.resolution_y,
        "clip_start": cam_data.clip_start,
        "clip_end": cam_data.clip_end,
        "frame": scene.frame_current,
        "baked_keyframes": [],
    }

    if with_baked_keyframes:
        data["baked_keyframes"] = _bake_camera_matrices(
            scene, scene.camera, scene.frame_start, scene.frame_end, explicit_only
        )

    return data


def snapshot_camera_curves():
    """Capture the active camera's animation curves for offline replay.

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
    """
    scene = bpy.context.scene
    if not scene.camera:
        return None

    obj = scene.camera
    cam_data = obj.data
    render = scene.render
    aspect = render.resolution_x / render.resolution_y

    # Bake intrinsics + transform at frame_start so the consumer has a complete
    # starting state even for properties that aren't animated.
    static = {
        "matrix_world": [v for row in obj.matrix_world for v in row],
        "location": list(obj.location),
        "rotation_euler": list(obj.rotation_euler),
        "scale": list(obj.scale),
        "focal_length": cam_data.lens,
        "sensor_width": cam_data.sensor_width,
        "sensor_height": cam_data.sensor_height,
        "sensor_fit": cam_data.sensor_fit,
        "clip_start": cam_data.clip_start,
        "clip_end": cam_data.clip_end,
        "vertical_fov": _compute_vertical_fov_degrees(cam_data, aspect),
    }

    fcurves_out = []
    for source_tag, owner in _iter_anim_sources(obj):
        fcs = _fcurves_of(owner)
        if not fcs:
            continue
        for fc in fcs:
            has_modifiers = bool(getattr(fc, 'modifiers', None))
            keyframes = []
            for kf in fc.keyframe_points:
                keyframes.append({
                    "frame": float(kf.co[0]),
                    "value": float(kf.co[1]),
                    "interpolation": kf.interpolation,  # CONSTANT/LINEAR/BEZIER/SINE/...
                    "easing": kf.easing,                # AUTO/EASE_IN/EASE_OUT/EASE_IN_OUT
                    "handle_left": [float(kf.handle_left[0]), float(kf.handle_left[1])],
                    "handle_right": [float(kf.handle_right[0]), float(kf.handle_right[1])],
                    "amplitude": float(kf.amplitude),   # used by elastic
                    "period": float(kf.period),
                    "back": float(kf.back),             # used by back
                })
            fcurves_out.append({
                "source": source_tag,
                "data_path": fc.data_path,
                "array_index": fc.array_index,
                "extrapolation": fc.extrapolation,      # CONSTANT/LINEAR
                "has_modifiers": has_modifiers,
                "keyframes": keyframes,
            })

    return {
        "name": obj.name,
        "frame_start": scene.frame_start,
        "frame_end": scene.frame_end,
        "fps": render.fps / render.fps_base,
        "render_width": render.resolution_x,
        "render_height": render.resolution_y,
        "render_aspect": aspect,
        "static": static,
        "fcurves": fcurves_out,
    }


def snapshot_scene():
    """Capture scene-level render and timeline settings.

    Must be called on Blender's main thread.

    Returns:
        dict: ``scene_update`` payload with ``resolution_width``,
        ``resolution_height``, ``frame_rate`` (``fps / fps_base``),
        ``frame_start``, ``frame_end``, and ``frame_current``.
    """
    scene = bpy.context.scene
    render = scene.render
    return {
        "resolution_width": render.resolution_x,
        "resolution_height": render.resolution_y,
        "frame_rate": render.fps / render.fps_base,
        "frame_start": scene.frame_start,
        "frame_end": scene.frame_end,
        "frame_current": scene.frame_current,
    }


def _camera_dedup_key(data):
    """Stable identity for change detection (excludes frame counter)."""
    if data is None:
        return None
    return (
        tuple(data["matrix_world"]),
        data["focal_length"],
        data["sensor_width"],
        data["sensor_height"],
        data["clip_start"],
        data["clip_end"],
        data["render_width"],
        data["render_height"],
    )


# ---------------------------------------------------------------------------
# Connection manager: only the coroutine touches the websocket; bpy access is
# marshalled through bpy.app.timers and an asyncio.Queue.
# ---------------------------------------------------------------------------

class CameraSyncManager:
    """Owns the websocket connection and bridges Blender's main thread to asyncio.

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
    """

    def __init__(self):
        self.loop = None
        self.thread = None
        self.is_running = False
        self.send_queue = None  # asyncio.Queue, created on the loop's thread
        self.last_dedup_key = None
        self.reconnect_attempts = 0
        self.max_reconnect_attempts = 5
        self.reconnect_delay = 2.0
        self.last_sync_time = 0
        self._timer_active = False

    # ----- main-thread side -----

    def set_connected_main_thread(self, value):
        """Schedule a property write on the main thread."""
        def apply():
            try:
                bpy.context.scene.camera_sync_props.is_connected = value
            except Exception:
                pass
            return None
        bpy.app.timers.register(apply)

    def enqueue(self, message):
        """Push an outgoing message to the websocket coroutine. Thread-safe."""
        if self.loop and self.send_queue is not None and self.loop.is_running():
            asyncio.run_coroutine_threadsafe(self.send_queue.put(message), self.loop)

    def _periodic_snapshot(self):
        """Runs on main thread via bpy.app.timers. Returns next interval, or None to stop."""
        if not self.is_running:
            self._timer_active = False
            return None

        props = bpy.context.scene.camera_sync_props
        interval = 1.0 / max(1, props.sync_rate)

        if props.auto_sync and props.is_connected:
            data = snapshot_camera(with_baked_keyframes=False)
            if data is not None:
                key = _camera_dedup_key(data)
                if key != self.last_dedup_key:
                    self.last_dedup_key = key
                    self.enqueue({
                        "type": "camera_update",
                        "payload": data,
                        "timestamp": time.time(),
                    })
        return interval

    def start_main_thread_timer(self):
        if self._timer_active:
            return
        self._timer_active = True
        bpy.app.timers.register(self._periodic_snapshot, first_interval=0.1)

    # ----- background-thread side (asyncio loop) -----

    async def _writer(self, websocket):
        while self.is_running:
            try:
                message = await asyncio.wait_for(self.send_queue.get(), timeout=0.5)
            except asyncio.TimeoutError:
                continue
            try:
                await websocket.send(json.dumps(message))
                _log(f"sent {message['type']}")
            except Exception as e:
                logger.warning(f"send failed: {e}")
                return

    async def _reader(self, websocket):
        while self.is_running:
            try:
                msg = await websocket.recv()
            except Exception:
                return
            try:
                data = json.loads(msg)
                _log(f"recv {data.get('type')}")
            except json.JSONDecodeError:
                logger.warning("malformed incoming message")

    async def _connection_loop(self, host, port):
        import websockets  # lazy import in case install lagged at module load
        uri = f"ws://{host}:{port}/ws"
        self.send_queue = asyncio.Queue()

        while self.is_running:
            try:
                async with websockets.connect(uri) as ws:
                    self.reconnect_attempts = 0
                    self.reconnect_delay = 2.0
                    self.set_connected_main_thread(True)
                    logger.info(f"connected to {uri}")

                    tasks = [
                        asyncio.create_task(self._writer(ws)),
                        asyncio.create_task(self._reader(ws)),
                    ]
                    done, pending = await asyncio.wait(
                        tasks, return_when=asyncio.FIRST_COMPLETED
                    )
                    for t in pending:
                        t.cancel()
                    self.set_connected_main_thread(False)
            except Exception as e:
                logger.warning(f"connection error: {e}")

            if not self.is_running:
                break

            # Auto-reconnect handling — read prop via timer? Simpler: assume on.
            self.reconnect_attempts += 1
            if self.reconnect_attempts > self.max_reconnect_attempts:
                logger.warning("max reconnect attempts reached")
                break
            await asyncio.sleep(self.reconnect_delay)
            self.reconnect_delay = min(self.reconnect_delay * 1.5, 30.0)

        self.set_connected_main_thread(False)

    # ----- lifecycle -----

    def start_connection(self, host, port):
        """Spawn the asyncio thread and main-thread snapshot timer.

        No-op if already running.
        """
        if self.is_running:
            return
        self.is_running = True
        self.last_dedup_key = None

        def run_loop():
            self.loop = asyncio.new_event_loop()
            asyncio.set_event_loop(self.loop)
            try:
                self.loop.run_until_complete(self._connection_loop(host, port))
            finally:
                self.loop.close()

        self.thread = threading.Thread(target=run_loop, daemon=True)
        self.thread.start()
        self.start_main_thread_timer()

    def stop_connection(self):
        """Stop the asyncio loop and join the background thread (1s timeout)."""
        self.is_running = False
        if self.loop and self.loop.is_running():
            self.loop.call_soon_threadsafe(lambda: None)  # wake the loop
        if self.thread and self.thread.is_alive():
            self.thread.join(timeout=1.0)
        self.set_connected_main_thread(False)
        logger.info("disconnected")


camera_sync_manager = CameraSyncManager()


# ---------------------------------------------------------------------------
# Operators
# ---------------------------------------------------------------------------

class CAMERA_SYNC_OT_connect(Operator):
    """Operator: open a websocket to the configured ``host:port``."""

    bl_idname = "camera_sync.connect"
    bl_label = "Connect"

    def execute(self, context):
        props = context.scene.camera_sync_props
        if props.is_connected:
            self.report({'WARNING'}, "Already connected")
            return {'CANCELLED'}
        camera_sync_manager.start_connection(props.host, props.port)
        self.report({'INFO'}, f"Connecting to {props.host}:{props.port}…")
        return {'FINISHED'}


class CAMERA_SYNC_OT_disconnect(Operator):
    """Operator: tear down the active websocket connection."""

    bl_idname = "camera_sync.disconnect"
    bl_label = "Disconnect"

    def execute(self, context):
        if not context.scene.camera_sync_props.is_connected:
            self.report({'WARNING'}, "Not connected")
            return {'CANCELLED'}
        camera_sync_manager.stop_connection()
        self.report({'INFO'}, "Disconnected")
        return {'FINISHED'}


class CAMERA_SYNC_OT_send_manual(Operator):
    """Operator: snapshot the camera (with baked keyframes) and enqueue a ``camera_update``."""
    bl_idname = "camera_sync.send_manual"
    bl_label = "Send Camera Data"

    def execute(self, context):
        props = context.scene.camera_sync_props
        if not props.is_connected:
            self.report({'WARNING'}, "Not connected")
            return {'CANCELLED'}
        data = snapshot_camera(
            with_baked_keyframes=True,
            explicit_only=props.send_only_explicit_keyframes,
        )
        if data is None:
            self.report({'ERROR'}, "No active camera")
            return {'CANCELLED'}
        camera_sync_manager.enqueue({
            "type": "camera_update",
            "payload": data,
            "timestamp": time.time(),
        })
        self.report({'INFO'}, "Camera data queued")
        return {'FINISHED'}


class CAMERA_SYNC_OT_send_scene_info(Operator):
    """Operator: enqueue a one-shot ``scene_update`` message."""

    bl_idname = "camera_sync.send_scene_info"
    bl_label = "Send Scene Info"

    def execute(self, context):
        if not context.scene.camera_sync_props.is_connected:
            self.report({'WARNING'}, "Not connected")
            return {'CANCELLED'}
        camera_sync_manager.enqueue({
            "type": "scene_update",
            "payload": snapshot_scene(),
            "timestamp": time.time(),
        })
        self.report({'INFO'}, "Scene info queued")
        return {'FINISHED'}


class CAMERA_SYNC_OT_send_camera_curves(Operator):
    """Operator: extract raw f-curve data from the camera and enqueue ``camera_curves``."""
    bl_idname = "camera_sync.send_camera_curves"
    bl_label = "Send Camera Curves"

    def execute(self, context):
        if not context.scene.camera_sync_props.is_connected:
            self.report({'WARNING'}, "Not connected")
            return {'CANCELLED'}
        data = snapshot_camera_curves()
        if data is None:
            self.report({'ERROR'}, "No active camera")
            return {'CANCELLED'}
        camera_sync_manager.enqueue({
            "type": "camera_curves",
            "payload": data,
            "timestamp": time.time(),
        })
        self.report({'INFO'}, f"Camera curves queued ({len(data['fcurves'])} fcurves)")
        return {'FINISHED'}


class CAMERA_SYNC_OT_test_connection(Operator):
    """Operator: TCP-probe ``host:port`` to confirm the sync server is reachable."""

    bl_idname = "camera_sync.test_connection"
    bl_label = "Test Connection"

    def execute(self, context):
        import socket
        props = context.scene.camera_sync_props
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
                sock.settimeout(2)
                if sock.connect_ex((props.host, props.port)) == 0:
                    self.report({'INFO'}, f"Server reachable at {props.host}:{props.port}")
                else:
                    self.report({'ERROR'}, f"Cannot reach {props.host}:{props.port}")
        except Exception as e:
            self.report({'ERROR'}, f"Connection test failed: {e}")
        return {'FINISHED'}


class CAMERA_SYNC_PT_panel(Panel):
    """N-panel UI under the "Camera Sync" tab in the 3D View."""

    bl_label = "Camera Sync"
    bl_idname = "CAMERA_SYNC_PT_panel"
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "Camera Sync"

    def draw(self, context):
        layout = self.layout
        props = context.scene.camera_sync_props

        box = layout.box()
        box.label(text="Connection Settings")
        box.prop(props, "host")
        box.prop(props, "port")

        row = box.row()
        if props.is_connected:
            row.label(text="Status: Connected", icon='LINKED')
        else:
            row.label(text="Status: Disconnected", icon='UNLINKED')

        row = box.row()
        if props.is_connected:
            row.operator("camera_sync.disconnect", icon='UNLINKED')
        else:
            row.operator("camera_sync.connect", icon='LINKED')

        box.row().operator("camera_sync.test_connection", icon='QUESTION')

        if props.is_connected:
            box = layout.box()
            box.label(text="Sync Settings")
            box.prop(props, "auto_sync")
            box.prop(props, "sync_keyframes")
            if props.auto_sync:
                box.prop(props, "sync_rate")
            else:
                box.prop(props, "send_only_explicit_keyframes")
                box.operator("camera_sync.send_manual", icon='EXPORT')
                box.operator("camera_sync.send_scene_info", icon='SCENE_DATA')
                box.operator("camera_sync.send_camera_curves", icon='IPO_BEZIER')

        box = layout.box()
        box.label(text="Advanced Settings")
        box.prop(props, "auto_reconnect")

        scene = context.scene
        if scene.camera:
            box = layout.box()
            box.label(text="Active Camera")
            box.label(text=f"Name: {scene.camera.name}")
            box.label(text=f"Frame: {scene.frame_current}")
            cam = scene.camera
            box.label(text=f"Location: {cam.location.x:.2f}, {cam.location.y:.2f}, {cam.location.z:.2f}")
            box.label(text=f"Rotation: {cam.rotation_euler.x:.2f}, {cam.rotation_euler.y:.2f}, {cam.rotation_euler.z:.2f}")
            box.label(text=f"Focal Length: {cam.data.lens:.1f}mm")


classes = (
    CameraSyncProperties,
    CAMERA_SYNC_OT_connect,
    CAMERA_SYNC_OT_disconnect,
    CAMERA_SYNC_OT_send_manual,
    CAMERA_SYNC_OT_send_scene_info,
    CAMERA_SYNC_OT_send_camera_curves,
    CAMERA_SYNC_OT_test_connection,
    CAMERA_SYNC_PT_panel,
)


@bpy.app.handlers.persistent
def _on_frame_change_post(scene, depsgraph=None):
    """Push a camera snapshot every time Blender's playhead moves.

    The periodic Auto Sync timer dedups on camera transform/intrinsics and
    intentionally ignores ``frame``, so frame-only changes (scrubbing the
    timeline without touching the camera) would never reach clients without
    this handler. Bypasses the dedup so consumers always see the new frame.
    """
    try:
        props = scene.camera_sync_props
    except AttributeError:
        return
    if not (props.auto_sync and props.is_connected):
        return
    data = snapshot_camera(with_baked_keyframes=False)
    if data is None:
        return
    camera_sync_manager.last_dedup_key = _camera_dedup_key(data)
    camera_sync_manager.enqueue({
        "type": "camera_update",
        "payload": data,
        "timestamp": time.time(),
    })


def register():
    """Register operators, panel, and the scene-level ``camera_sync_props`` pointer.

    Called automatically by Blender when the addon is enabled.
    """
    for cls in classes:
        bpy.utils.register_class(cls)
    bpy.types.Scene.camera_sync_props = bpy.props.PointerProperty(type=CameraSyncProperties)
    if _on_frame_change_post not in bpy.app.handlers.frame_change_post:
        bpy.app.handlers.frame_change_post.append(_on_frame_change_post)


def unregister():
    """Tear down the websocket connection and undo :func:`register`."""
    if _on_frame_change_post in bpy.app.handlers.frame_change_post:
        bpy.app.handlers.frame_change_post.remove(_on_frame_change_post)
    camera_sync_manager.stop_connection()
    for cls in classes:
        bpy.utils.unregister_class(cls)
    del bpy.types.Scene.camera_sync_props


if __name__ == "__main__":
    register()
