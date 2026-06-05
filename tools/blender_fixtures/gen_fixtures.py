"""Generate golden animation fixtures from a real Blender runtime.

Run headless::

    "$WABF_BLENDER" --background --python tools/blender_fixtures/gen_fixtures.py

For each parametrized scene this script:

1. Authors the scene with `bpy` (keyframes, parenting, constraints, drivers).
2. Emits the **exact** `object_graph` wire payload via the shipped addon
   exporter (`bl_camera_sync/export.py`) — so the fixtures test the real import
   path, not a hand-built DTO.
3. Bakes the depsgraph-evaluated `matrix_world` of every object at every integer
   frame as the **golden** ground truth.

Output: `Tests/BlenderSyncServerTests/Fixtures/<scene>.json` with shape::

    { "scene": str,
      "wire":   <object_graph payload>,
      "golden": [ { "frame": int, "object": str, "matrix_world": [16 floats] } ] }

The matching consumer is `Tests/BlenderSyncServerTests` (schema-decode today;
the WABFCoreKit `TransformGraph` evaluator compares against `golden` later).
"""

import json
import math
import os
import sys

import bpy

# --- locate the addon exporter (import export.py without the addon __init__) ---
_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.abspath(os.path.join(_HERE, "..", ".."))
_ADDON_DIR = os.path.join(_REPO, "blender-addon", "bl_camera_sync")
sys.path.insert(0, _ADDON_DIR)
import export as obj_export  # noqa: E402  (bl_camera_sync/export.py)

OUT_DIR = os.path.join(_REPO, "Tests", "BlenderSyncServerTests", "Fixtures")

FRAME_START = 1
FRAME_END = 12


# ---------------------------------------------------------------------------
# Authoring helpers
# ---------------------------------------------------------------------------

def reset_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.frame_start = FRAME_START
    scene.frame_end = FRAME_END
    return scene


def add_cube(name, location=(0, 0, 0), rotation_mode='XYZ'):
    mesh = bpy.data.meshes.new(name + "_mesh")
    obj = bpy.data.objects.new(name, mesh)
    obj.rotation_mode = rotation_mode
    obj.location = location
    bpy.context.collection.objects.link(obj)
    return obj


def add_empty(name, location=(0, 0, 0)):
    obj = bpy.data.objects.new(name, None)
    obj.location = location
    bpy.context.collection.objects.link(obj)
    return obj


def key(obj, data_path, frame, interpolation='BEZIER'):
    obj.keyframe_insert(data_path=data_path, frame=frame)
    # Set interpolation on the just-inserted keys (slotted-action aware).
    fcs = obj_export._fcurves_of(obj)
    if not fcs:
        return
    for fc in fcs:
        if fc.data_path != data_path:
            continue
        for kf in fc.keyframe_points:
            if abs(kf.co[0] - frame) < 1e-6:
                kf.interpolation = interpolation


# ---------------------------------------------------------------------------
# Scenes
# ---------------------------------------------------------------------------

def scene_euler_orders():
    """One cube per euler order, each with keyed location + rotation + scale."""
    reset_scene()
    orders = ['XYZ', 'XZY', 'YXZ', 'YZX', 'ZXY', 'ZYX']
    for i, order in enumerate(orders):
        c = add_cube(f"Cube_{order}", location=(i * 3, 0, 0), rotation_mode=order)
        # frame 1: rest
        c.location = (i * 3, 0, 0)
        c.rotation_euler = (0, 0, 0)
        c.scale = (1, 1, 1)
        key(c, "location", FRAME_START)
        key(c, "rotation_euler", FRAME_START)
        key(c, "scale", FRAME_START)
        # frame 12: rotated/scaled/moved (distinct per axis so order matters)
        c.location = (i * 3 + 1.5, 2.0, -1.0)
        c.rotation_euler = (math.radians(35), math.radians(50), math.radians(20))
        c.scale = (1.5, 0.8, 1.2)
        key(c, "location", FRAME_END)
        key(c, "rotation_euler", FRAME_END)
        key(c, "scale", FRAME_END)
    return "euler_orders"


def scene_quat_axisangle():
    reset_scene()
    q = add_cube("Cube_Quat", location=(0, 0, 0), rotation_mode='QUATERNION')
    q.rotation_quaternion = (1, 0, 0, 0)
    key(q, "location", FRAME_START)
    key(q, "rotation_quaternion", FRAME_START)
    import mathutils
    q.rotation_quaternion = mathutils.Euler(
        (math.radians(40), math.radians(25), math.radians(60)), 'XYZ').to_quaternion()
    q.location = (1, 2, 3)
    key(q, "location", FRAME_END)
    key(q, "rotation_quaternion", FRAME_END)

    a = add_cube("Cube_Axis", location=(4, 0, 0), rotation_mode='AXIS_ANGLE')
    a.rotation_axis_angle = (0, 0, 0, 1)
    key(a, "rotation_axis_angle", FRAME_START)
    a.rotation_axis_angle = (math.radians(90), 0.3, 0.6, 0.7)
    key(a, "rotation_axis_angle", FRAME_END)
    return "quat_axisangle"


def scene_parent_chain():
    """Empty (keyed) → child cube (local offset, keyed) → grandchild cube."""
    reset_scene()
    root = add_empty("Root", location=(0, 0, 0))
    root.rotation_euler = (0, 0, 0)
    key(root, "location", FRAME_START)
    key(root, "rotation_euler", FRAME_START)
    root.location = (2, 1, 0)
    root.rotation_euler = (0, 0, math.radians(90))
    key(root, "location", FRAME_END)
    key(root, "rotation_euler", FRAME_END)

    child = add_cube("Child", location=(1, 0, 0))
    child.parent = root
    child.matrix_parent_inverse = root.matrix_world.inverted()
    key(child, "location", FRAME_START)
    child.location = (1, 0, 2)
    key(child, "location", FRAME_END)

    grand = add_cube("Grandchild", location=(0.5, 0, 0))
    grand.parent = child
    grand.matrix_parent_inverse = child.matrix_world.inverted()
    return "parent_chain"


def scene_track_to():
    """Cube with a Track To constraint aimed at a keyed empty (baked fallback)."""
    reset_scene()
    target = add_empty("Target", location=(5, 0, 0))
    key(target, "location", FRAME_START)
    target.location = (5, 5, 3)
    key(target, "location", FRAME_END)

    cube = add_cube("Tracker", location=(0, 0, 0))
    con = cube.constraints.new(type='TRACK_TO')
    con.target = target
    con.track_axis = 'TRACK_NEGATIVE_Z'
    con.up_axis = 'UP_Y'
    return "track_to"


def scene_copy_location():
    """Cube with Copy Location → a keyed empty (native constraint)."""
    reset_scene()
    target = add_empty("Target", location=(0, 0, 0))
    key(target, "location", FRAME_START)
    target.location = (3, 2, 4)
    key(target, "location", FRAME_END)

    cube = add_cube("Copier", location=(-2, -2, 0))
    cube.rotation_euler = (math.radians(20), 0, math.radians(45))  # kept (only loc copied)
    con = cube.constraints.new(type='COPY_LOCATION')
    con.target = target
    return "copy_location"


def scene_copy_transforms():
    """Cube with Copy Transforms → a keyed empty (loc+rot+scale)."""
    reset_scene()
    target = add_empty("Target", location=(0, 0, 0))
    key(target, "location", FRAME_START)
    key(target, "rotation_euler", FRAME_START)
    key(target, "scale", FRAME_START)
    target.location = (2, 3, 1)
    target.rotation_euler = (math.radians(30), math.radians(40), math.radians(10))
    target.scale = (1.4, 0.7, 1.1)
    key(target, "location", FRAME_END)
    key(target, "rotation_euler", FRAME_END)
    key(target, "scale", FRAME_END)

    cube = add_cube("Copier", location=(-3, 0, 0))
    con = cube.constraints.new(type='COPY_TRANSFORMS')
    con.target = target
    return "copy_transforms"


def scene_child_of():
    """Cube with Child Of → a keyed empty (matrix parenting via inverse)."""
    reset_scene()
    scene = bpy.context.scene
    target = add_empty("Pivot", location=(0, 0, 0))
    key(target, "location", FRAME_START)
    key(target, "rotation_euler", FRAME_START)
    target.location = (2, 0, 1)
    target.rotation_euler = (0, 0, math.radians(120))
    key(target, "location", FRAME_END)
    key(target, "rotation_euler", FRAME_END)

    cube = add_cube("ChildOf", location=(1.5, 0, 0))
    con = cube.constraints.new(type='CHILD_OF')
    con.target = target
    # Bind the inverse at the rest frame (like the "Set Inverse" operator).
    scene.frame_set(FRAME_START)
    bpy.context.view_layer.update()
    con.inverse_matrix = target.matrix_world.inverted()
    return "child_of"


def scene_copy_scale():
    """Cube with Copy Scale → a keyed empty (per-axis scale)."""
    reset_scene()
    target = add_empty("Target", location=(0, 0, 0))
    key(target, "scale", FRAME_START)
    target.scale = (2.0, 0.5, 1.5)
    key(target, "scale", FRAME_END)

    cube = add_cube("Scaler", location=(0, 0, 0))
    cube.rotation_euler = (math.radians(25), 0, math.radians(30))  # kept
    con = cube.constraints.new(type='COPY_SCALE')
    con.target = target
    return "copy_scale"


def scene_limit_location():
    """Cube animated past a ceiling, clamped by Limit Location (world)."""
    reset_scene()
    cube = add_cube("Limited", location=(0, 0, 0))
    key(cube, "location", FRAME_START)
    cube.location = (5, 5, 5)
    key(cube, "location", FRAME_END)
    con = cube.constraints.new(type='LIMIT_LOCATION')
    con.use_max_x = True
    con.max_x = 2.0
    con.use_max_z = True
    con.max_z = 3.0
    con.owner_space = 'WORLD'
    return "limit_location"


def scene_limit_scale():
    """Cube animated to grow, clamped by Limit Scale (world)."""
    reset_scene()
    cube = add_cube("Limited", location=(0, 0, 0))
    key(cube, "scale", FRAME_START)
    cube.scale = (3, 3, 3)
    key(cube, "scale", FRAME_END)
    con = cube.constraints.new(type='LIMIT_SCALE')
    con.use_max_x = True
    con.max_x = 1.5
    con.use_max_y = True
    con.max_y = 2.0
    con.owner_space = 'WORLD'
    return "limit_scale"


def scene_damped_track():
    """Cube with Damped Track → a keyed empty (track Y, shortest-arc)."""
    reset_scene()
    target = add_empty("Target", location=(4, 0, 0))
    key(target, "location", FRAME_START)
    target.location = (4, 4, 2)
    key(target, "location", FRAME_END)

    cube = add_cube("Damper", location=(0, 0, 0))
    con = cube.constraints.new(type='DAMPED_TRACK')
    con.target = target
    con.track_axis = 'TRACK_Y'
    return "damped_track"


def scene_copy_rotation():
    """Cube with Copy Rotation → a keyed empty (all axes, REPLACE)."""
    reset_scene()
    target = add_empty("Target", location=(0, 0, 0))
    key(target, "rotation_euler", FRAME_START)
    target.rotation_euler = (math.radians(40), math.radians(25), math.radians(70))
    key(target, "rotation_euler", FRAME_END)

    cube = add_cube("Rotator", location=(0, 0, 0))
    cube.location = (1, 1, 1)   # kept (only rotation copied)
    cube.scale = (1.3, 0.8, 1.0)
    con = cube.constraints.new(type='COPY_ROTATION')
    con.target = target
    return "copy_rotation"


def scene_locked_track():
    """Cube with Locked Track (lock Z, track Y) → a keyed empty."""
    reset_scene()
    target = add_empty("Target", location=(4, 0, 0))
    key(target, "location", FRAME_START)
    target.location = (3, 5, 2)
    key(target, "location", FRAME_END)

    cube = add_cube("Locker", location=(0, 0, 0))
    con = cube.constraints.new(type='LOCKED_TRACK')
    con.target = target
    con.track_axis = 'TRACK_Y'
    con.lock_axis = 'LOCK_Z'
    return "locked_track"


def scene_limit_rotation():
    """Cube rotating past a cap, clamped by Limit Rotation (Z)."""
    reset_scene()
    cube = add_cube("Limited", location=(0, 0, 0))
    key(cube, "rotation_euler", FRAME_START)
    cube.rotation_euler = (0, 0, math.radians(120))
    key(cube, "rotation_euler", FRAME_END)
    con = cube.constraints.new(type='LIMIT_ROTATION')
    con.use_limit_z = True
    con.min_z = 0.0
    con.max_z = math.radians(45)
    con.owner_space = 'WORLD'
    return "limit_rotation"


def scene_copy_rotation_z():
    """Copy Rotation, Z axis only — owner keeps its X/Y, takes target Z."""
    reset_scene()
    target = add_empty("Target", location=(0, 0, 0))
    key(target, "rotation_euler", FRAME_START)
    target.rotation_euler = (math.radians(50), math.radians(20), math.radians(80))
    key(target, "rotation_euler", FRAME_END)

    cube = add_cube("Rotator", location=(0, 0, 0))
    cube.rotation_euler = (math.radians(20), math.radians(35), 0)  # static base (X/Y kept)
    con = cube.constraints.new(type='COPY_ROTATION')
    con.target = target
    con.use_x = False
    con.use_y = False
    con.use_z = True
    return "copy_rotation_z"


def scene_copy_rotation_before():
    """Copy Rotation, mix mode BEFORE (target * owner)."""
    reset_scene()
    target = add_empty("Target", location=(0, 0, 0))
    key(target, "rotation_euler", FRAME_START)
    target.rotation_euler = (0, 0, math.radians(90))
    key(target, "rotation_euler", FRAME_END)

    cube = add_cube("Rotator", location=(0, 0, 0))
    cube.rotation_euler = (math.radians(30), 0, 0)  # static base
    con = cube.constraints.new(type='COPY_ROTATION')
    con.target = target
    con.mix_mode = 'BEFORE'
    return "copy_rotation_before"


def scene_copy_rotation_order():
    """Copy Rotation with an explicit (non-AUTO) euler order ZYX."""
    reset_scene()
    target = add_empty("Target", location=(0, 0, 0))
    key(target, "rotation_euler", FRAME_START)
    target.rotation_euler = (math.radians(35), math.radians(45), math.radians(25))
    key(target, "rotation_euler", FRAME_END)

    cube = add_cube("Rotator", location=(0, 0, 0))  # owner rotmode XYZ
    con = cube.constraints.new(type='COPY_ROTATION')
    con.target = target
    con.euler_order = 'ZYX'
    return "copy_rotation_order"


def scene_track_to_influence():
    """Track To at 0.5 influence (blended pose)."""
    reset_scene()
    target = add_empty("Target", location=(5, 0, 0))
    key(target, "location", FRAME_START)
    target.location = (5, 5, 3)
    key(target, "location", FRAME_END)

    cube = add_cube("Tracker", location=(0, 0, 0))
    cube.rotation_euler = (math.radians(15), math.radians(10), 0)  # base pose to blend from
    con = cube.constraints.new(type='TRACK_TO')
    con.target = target
    con.track_axis = 'TRACK_NEGATIVE_Z'
    con.up_axis = 'UP_Y'
    con.influence = 0.5
    return "track_to_influence"


def scene_copy_location_offset():
    """Copy Location with offset + X inverted."""
    reset_scene()
    target = add_empty("Target", location=(0, 0, 0))
    key(target, "location", FRAME_START)
    target.location = (3, 2, 1)
    key(target, "location", FRAME_END)

    cube = add_cube("Copier", location=(1, 1, 1))  # base offset
    con = cube.constraints.new(type='COPY_LOCATION')
    con.target = target
    con.use_offset = True
    con.invert_x = True
    return "copy_location_offset"


def scene_driver():
    """Cube whose X is driven by a keyed empty's X (baked fallback)."""
    reset_scene()
    src = add_empty("Driver", location=(0, 0, 0))
    key(src, "location", FRAME_START)
    src.location = (4, 0, 0)
    key(src, "location", FRAME_END)

    cube = add_cube("Driven", location=(0, 2, 0))
    fcurve = cube.driver_add("location", 0)
    drv = fcurve.driver
    drv.type = 'SCRIPTED'
    var = drv.variables.new()
    var.name = "x"
    var.type = 'TRANSFORMS'
    tgt = var.targets[0]
    tgt.id = src
    tgt.transform_type = 'LOC_X'
    tgt.transform_space = 'WORLD_SPACE'
    drv.expression = "x * 2"
    return "driver"


SCENES = [
    scene_euler_orders,
    scene_quat_axisangle,
    scene_parent_chain,
    scene_track_to,
    scene_copy_location,
    scene_copy_transforms,
    scene_copy_scale,
    scene_copy_rotation,
    scene_child_of,
    scene_damped_track,
    scene_locked_track,
    scene_limit_location,
    scene_limit_rotation,
    scene_limit_scale,
    scene_copy_rotation_z,
    scene_copy_rotation_before,
    scene_copy_rotation_order,
    scene_track_to_influence,
    scene_copy_location_offset,
    scene_driver,
]


# ---------------------------------------------------------------------------
# Golden capture
# ---------------------------------------------------------------------------

def bake_golden(scene):
    golden = []
    original = scene.frame_current
    objs = list(scene.objects)
    try:
        for frame in range(FRAME_START, FRAME_END + 1):
            scene.frame_set(frame)
            dg = bpy.context.evaluated_depsgraph_get()
            for o in objs:
                ev = o.evaluated_get(dg)
                golden.append({
                    "frame": frame,
                    "object": o.name,
                    "matrix_world": [float(v) for row in ev.matrix_world for v in row],
                })
    finally:
        scene.frame_set(original)
    return golden


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    for build in SCENES:
        name = build()
        scene = bpy.context.scene
        wire = obj_export.snapshot_object_graph(bpy.context, scope='ALL')
        golden = bake_golden(scene)
        fixture = {"scene": name, "wire": wire, "golden": golden}
        path = os.path.join(OUT_DIR, f"{name}.json")
        with open(path, "w") as f:
            json.dump(fixture, f, indent=1)
        baked = sum(1 for o in wire["objects"] if o["needs_bake"])
        print(f"[fixtures] {name}: {len(wire['objects'])} objects "
              f"({baked} baked), {len(golden)} golden samples → {path}")


if __name__ == "__main__":
    main()
