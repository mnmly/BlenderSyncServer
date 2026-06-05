"""Save a demo scene to a .blend for eyeball comparison with WABF.

    WABF_DEMO_SCENE=child_of "$WABF_BLENDER" --background --factory-startup \
        --python tools/blender_fixtures/save_demo_blend.py

`WABF_DEMO_SCENE` selects which `gen_fixtures.scene_*` to build (default
`euler_orders`): euler_orders, quat_axisangle, parent_chain, track_to,
copy_location, copy_transforms, child_of, damped_track, driver.

Open the resulting .blend, press Space to play (range is 1–12) — it's the same
animation WABF replays from that fixture's object graph.
"""

import os
import sys

import bpy
import bmesh

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_fixtures as gf  # noqa: E402

scene_name = os.environ.get("WABF_DEMO_SCENE", "euler_orders")
getattr(gf, "scene_" + scene_name)()

# The fixture builder uses empty meshes (only matrix_world matters for golden
# baking). For an eyeball demo, fill each object's mesh with real cube geometry
# — the object-level animation/transform is untouched, so it still matches the
# `euler_orders` fixture exactly.
for obj in bpy.context.scene.objects:
    if obj.type == 'MESH' and len(obj.data.vertices) == 0:
        bm = bmesh.new()
        bmesh.ops.create_cube(bm, size=1.5)
        bm.to_mesh(obj.data)
        bm.free()

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), scene_name + "_demo.blend")
bpy.ops.wm.save_as_mainfile(filepath=out)
print("[demo] saved", out)
