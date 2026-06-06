"""Object-graph export for bl_camera_sync.

Self-contained (only ``bpy`` / ``mathutils`` / stdlib) so the headless fixture
harness can import this module directly and emit the *exact* wire payload the
shipped addon sends — no drift between what we test and what we ship.

Wire message (``type == "object_graph"``)::

    { "type": "object_graph", "timestamp": <float>, "payload": {
        "frame_start": int, "frame_end": int, "fps": float,
        "render_width": int, "render_height": int, "render_aspect": float,
        "objects": [ <object>, ... ]
    }}

Each ``<object>`` is produced by :func:`export_object`. The matching Swift
decoder is ``BlenderSyncServer/ObjectGraph.swift``.

All ``bpy.*`` access must happen on Blender's main thread.
"""

import math

import bpy  # noqa: F401  (available inside Blender / the harness)


# ---------------------------------------------------------------------------
# F-curve access (kept independent of __init__.py so the harness can import us
# without pulling in the websocket/install machinery)
# ---------------------------------------------------------------------------

def _fcurves_of(anim_owner):
    """Return the fcurves iterable for an anim-data owner, across Blender 4.x/5.x."""
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


def _mat16(matrix):
    """Flatten a ``mathutils.Matrix`` to 16 row-major floats (Blender iterates rows)."""
    return [float(v) for row in matrix for v in row]


def _export_fcurves_from(owner, source):
    """Export every fcurve on an anim-data owner, tagged with `source`."""
    out = []
    fcs = _fcurves_of(owner)
    if not fcs:
        return out
    for fc in fcs:
        keyframes = []
        for kf in fc.keyframe_points:
            keyframes.append({
                "frame": float(kf.co[0]),
                "value": float(kf.co[1]),
                "interpolation": kf.interpolation,
                "easing": kf.easing,
                "handle_left": [float(kf.handle_left[0]), float(kf.handle_left[1])],
                "handle_right": [float(kf.handle_right[0]), float(kf.handle_right[1])],
                "amplitude": float(kf.amplitude),
                "period": float(kf.period),
                "back": float(kf.back),
            })
        out.append({
            "source": source,
            "data_path": fc.data_path,
            "array_index": fc.array_index,
            "extrapolation": fc.extrapolation,
            "has_modifiers": bool(getattr(fc, 'modifiers', None)),
            "keyframes": keyframes,
        })
    return out


def _export_fcurves(obj):
    """Object-level transform/animation fcurves (source == "object").

    Constraint-influence curves (``data_path`` like ``constraints["X"].influence``)
    also live on the object's action and are included verbatim.
    """
    return _export_fcurves_from(obj, "object")


def _export_camera(obj):
    """Camera intrinsics block (static + animated lens/sensor/clip) or None."""
    if obj.type != 'CAMERA':
        return None
    cam = obj.data
    return {
        "focal_length": cam.lens,
        "sensor_width": cam.sensor_width,
        "sensor_height": cam.sensor_height,
        "clip_start": cam.clip_start,
        "clip_end": cam.clip_end,
        "sensor_fit": cam.sensor_fit,
        "fcurves": _export_fcurves_from(cam, "data"),
    }


# ---------------------------------------------------------------------------
# Curves (NURBS / Bezier / Poly paths)
# ---------------------------------------------------------------------------

def _export_spline(spline):
    """Serialize one spline of a curve data-block.

    Point geometry is split by ``type``: BEZIER splines expose
    ``bezier_points`` (with handles); POLY/NURBS expose ``points`` whose
    ``co`` is 4D ``(x, y, z, w)`` — ``w`` is the rational NURBS weight.
    """
    out = {
        "type": spline.type,                 # 'POLY' | 'BEZIER' | 'NURBS'
        "use_cyclic_u": spline.use_cyclic_u,
        "resolution_u": spline.resolution_u,
        "order_u": spline.order_u,            # NURBS basis order; benign for others
        "use_endpoint_u": spline.use_endpoint_u,
        "use_bezier_u": spline.use_bezier_u,
    }
    if spline.type == 'BEZIER':
        out["bezier_points"] = [
            {
                "co": list(p.co),                       # (x, y, z)
                "handle_left": list(p.handle_left),
                "handle_right": list(p.handle_right),
                "handle_left_type": p.handle_left_type,
                "handle_right_type": p.handle_right_type,
                "tilt": p.tilt,
                "radius": p.radius,
            }
            for p in spline.bezier_points
        ]
    else:
        out["points"] = [
            {
                "co": list(p.co),                       # (x, y, z, w) — w is NURBS weight
                "tilt": p.tilt,
                "radius": p.radius,
                "weight": p.weight,
            }
            for p in spline.points
        ]
    return out


def _export_curve(obj):
    """Curve data-block (splines + path/timing settings) for CURVE objects, else None.

    ``use_path`` / ``path_duration`` / ``eval_time`` drive Follow Path timing;
    the splines are the control geometry needed to evaluate the path.
    """
    if obj.type != 'CURVE':
        return None
    cu = obj.data
    return {
        "dimensions": cu.dimensions,         # '2D' | '3D'
        "resolution_u": cu.resolution_u,
        "use_path": cu.use_path,
        "path_duration": cu.path_duration,
        "eval_time": cu.eval_time,
        "bevel_depth": cu.bevel_depth,
        "extrude": cu.extrude,
        "splines": [_export_spline(s) for s in cu.splines],
        "fcurves": _export_fcurves_from(cu, "data"),
    }


# ---------------------------------------------------------------------------
# Constraints
# ---------------------------------------------------------------------------

# Keys we probe per constraint. Missing attributes are simply omitted; the Swift
# ConstraintParams struct decodes every field as optional.
_CONSTRAINT_PARAM_ATTRS = (
    # Track / Damped / Locked
    "track_axis", "up_axis", "lock_axis",
    "target_space", "owner_space", "head_tail",
    # Copy*
    "use_x", "use_y", "use_z",
    "invert_x", "invert_y", "invert_z",
    "use_offset", "mix_mode", "euler_order", "power",
    # Limit*
    "use_min_x", "use_max_x", "use_min_y", "use_max_y", "use_min_z", "use_max_z",
    "min_x", "max_x", "min_y", "max_y", "min_z", "max_z",
    "use_limit_x", "use_limit_y", "use_limit_z",
    "use_transform_limit",
    # Child Of
    "use_location_x", "use_location_y", "use_location_z",
    "use_rotation_x", "use_rotation_y", "use_rotation_z",
    "use_scale_x", "use_scale_y", "use_scale_z",
    # Follow Path
    "use_curve_follow", "use_fixed_location", "use_curve_radius",
    "offset", "offset_factor", "forward_axis",
)


def _export_constraint(c):
    params = {}
    for attr in _CONSTRAINT_PARAM_ATTRS:
        if hasattr(c, attr):
            v = getattr(c, attr)
            if isinstance(v, bool):
                params[attr] = bool(v)
            elif isinstance(v, (int, float)):
                params[attr] = float(v)
            else:
                params[attr] = str(v)
    # Child Of bakes a correction matrix that must be applied verbatim.
    if hasattr(c, "inverse_matrix"):
        params["inverse_matrix"] = _mat16(c.inverse_matrix)

    target = getattr(c, "target", None)
    return {
        "type": c.type,
        "name": c.name,
        "influence": float(getattr(c, "influence", 1.0)),
        "mute": bool(getattr(c, "mute", False)),
        "target": target.name if target else None,
        "subtarget": getattr(c, "subtarget", "") or None,
        "params": params,
    }


# Constraint types the WABF Core solver reproduces natively (Constraints.swift).
# Anything outside this set (or with a bone subtarget / non-OBJECT parent /
# drivers / fcurve modifiers) forces the baked-matrix fallback.
_SOLVED_CONSTRAINTS = frozenset({
    "CHILD_OF", "COPY_LOCATION", "COPY_ROTATION", "COPY_SCALE", "COPY_TRANSFORMS",
    "TRACK_TO", "DAMPED_TRACK", "LOCKED_TRACK",
    "LIMIT_LOCATION", "LIMIT_ROTATION", "LIMIT_SCALE",
    # Follow Path is reproduced natively by WABFCoreKit's solver + the TinySpline
    # curve sampler (the curve geometry rides along in the object graph), so its
    # objects no longer force the baked-matrix fallback.
    "FOLLOW_PATH",
})


def _object_needs_bake(obj):
    """True if the Core engine can't (yet) reproduce this object from raw data."""
    if obj.parent is not None and obj.parent_type != 'OBJECT':
        return True
    for c in obj.constraints:
        if c.mute:
            continue
        if c.type not in _SOLVED_CONSTRAINTS:
            return True
        if getattr(c, "subtarget", ""):
            return True
    ad = obj.animation_data
    if ad and getattr(ad, "drivers", None) and len(ad.drivers) > 0:
        return True
    fcs = _fcurves_of(obj)
    if fcs:
        for fc in fcs:
            if getattr(fc, 'modifiers', None):
                return True
    return False


def _bake_object_matrices(scene, obj, start, end):
    """Evaluate ``obj.matrix_world`` at each integer frame in ``[start, end]``.

    Steps the timeline so parents, constraints, and drivers fully resolve via
    the depsgraph, then restores the original frame in ``finally``.

    Returns ``list[{"frame": int, "matrix_world": [16 floats row-major]}]``.
    """
    frames = []
    original = scene.frame_current
    try:
        for frame in range(start, end + 1):
            scene.frame_set(frame)
            depsgraph = bpy.context.evaluated_depsgraph_get()
            ev = obj.evaluated_get(depsgraph)
            frames.append({"frame": frame, "matrix_world": _mat16(ev.matrix_world)})
    finally:
        scene.frame_set(original)
    return frames


# ---------------------------------------------------------------------------
# Object export
# ---------------------------------------------------------------------------

def export_object(obj, scene, frame_start, frame_end, force_bake=False):
    """Serialize one object's transform authoring data + (optional) baked track.

    The captured ``base`` block is read at the *current* scene frame and acts as
    the fallback for any channel that isn't animated. Callers that want the
    canonical rest pose should ``scene.frame_set(frame_start)`` beforehand.
    """
    rot_mode = obj.rotation_mode
    base = {
        "location": list(obj.location),
        "scale": list(obj.scale),
        "rotation_euler": list(obj.rotation_euler),
        "rotation_quaternion": list(obj.rotation_quaternion),   # (w, x, y, z)
        "rotation_axis_angle": list(obj.rotation_axis_angle),    # (angle, x, y, z)
        "delta_location": list(obj.delta_location),
        "delta_scale": list(obj.delta_scale),
        "delta_rotation_euler": list(obj.delta_rotation_euler),
        "delta_rotation_quaternion": list(obj.delta_rotation_quaternion),
        "matrix_local": _mat16(obj.matrix_local),
        "matrix_world": _mat16(obj.matrix_world),
    }

    needs_bake = force_bake or _object_needs_bake(obj)
    baked = None
    if needs_bake:
        reason = "forced" if force_bake else "unsupported"
        baked = {
            "reason": reason,
            "frames": _bake_object_matrices(scene, obj, frame_start, frame_end),
        }

    parent = obj.parent
    return {
        "name": obj.name,
        "id": obj.name,
        "type": obj.type,
        "rotation_mode": rot_mode,
        "base": base,
        "parent": parent.name if parent else None,
        "parent_inverse": _mat16(obj.matrix_parent_inverse),
        "parent_type": obj.parent_type,
        "constraints": [_export_constraint(c) for c in obj.constraints],
        "fcurves": _export_fcurves(obj),
        "camera": _export_camera(obj),
        "curve": _export_curve(obj),
        "baked": baked,
        "needs_bake": needs_bake,
    }


def _objects_for_scope(context, scope):
    scene = context.scene
    if scope == 'SELECTED':
        objs = list(context.selected_objects)
    elif scope == 'VISIBLE':
        objs = [o for o in scene.objects if o.visible_get()]
    else:  # 'ALL'
        objs = list(scene.objects)
    return objs


def snapshot_object_graph(context, scope='VISIBLE'):
    """Build the ``object_graph`` payload for the chosen object scope.

    Args:
        context: ``bpy.context``.
        scope: ``'ALL'`` | ``'VISIBLE'`` | ``'SELECTED'``.

    Returns:
        dict payload (see module docstring). Captures ``base`` at
        ``frame_start`` and restores the original frame afterward.
    """
    scene = context.scene
    render = scene.render
    aspect = render.resolution_x / max(render.resolution_y, 1)
    start, end = scene.frame_start, scene.frame_end

    objs = _objects_for_scope(context, scope)

    original = scene.frame_current
    try:
        scene.frame_set(start)
        objects = [export_object(o, scene, start, end) for o in objs]
    finally:
        scene.frame_set(original)

    return {
        "frame_start": start,
        "frame_end": end,
        "fps": render.fps / render.fps_base,
        "render_width": render.resolution_x,
        "render_height": render.resolution_y,
        "render_aspect": aspect,
        "objects": objects,
    }
