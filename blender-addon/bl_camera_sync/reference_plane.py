"""Import a WABF "reference plane": a flat top-down PNG exported from WABF plus a
sidecar JSON describing the exact world rectangle it covers.

WABF (``SketchBase.exportReferencePlane``) renders an orthographic top-down image
of its point clouds and writes ``name.png`` + ``name.json``. The JSON gives, in
**Blender Z-up space** (WABF's origin-shifted render frame), the plane's center,
size, and image-axis mapping. This operator builds a textured, unlit plane at
exactly that transform so the user can block out a scene against the cloud — and
because the plane sits in the same frame the clouds use, objects placed on it
round-trip back into WABF via "Send Object Graph" and land on the cloud.

JSON shape (see ``ReferencePlaneMetadata`` on the WABF side)::

    {
      "version": 1,
      "coordinate_space": "wabf_render",
      "basis": "blender_z_up",
      "image": "name.png",
      "image_resolution": [w, h],
      "plane_center": [x, y, z],
      "plane_size": [size_x, size_y],
      "u_axis": [1, 0, 0],
      "v_axis": [0, -1, 0],
      "pixels_per_meter": 16.0,
      "crs": "EPSG:3857",            # informational
      "reference_origin": [ox,oy,oz],# informational (true world origin)
      "absolute_center": [ ... ]     # informational
    }
"""

import os
import json

import bpy
from bpy.types import Operator
from bpy.props import StringProperty
from bpy_extras.io_utils import ImportHelper

REFERENCE_COLLECTION = "WABF Reference"


def _ensure_collection(name):
    """Return a scene collection named ``name``, creating + linking it if absent."""
    coll = bpy.data.collections.get(name)
    if coll is None:
        coll = bpy.data.collections.new(name)
        bpy.context.scene.collection.children.link(coll)
    return coll


def _build_material(name, image):
    """Unlit (emission) material showing ``image`` with straight-alpha cutout."""
    mat = bpy.data.materials.new(name=name)
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()

    out = nt.nodes.new("ShaderNodeOutputMaterial")
    out.location = (400, 0)
    mix = nt.nodes.new("ShaderNodeMixShader")
    mix.location = (200, 0)
    emit = nt.nodes.new("ShaderNodeEmission")
    emit.location = (0, -120)
    transp = nt.nodes.new("ShaderNodeBsdfTransparent")
    transp.location = (0, 120)
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.location = (-300, 0)
    tex.image = image

    nt.links.new(tex.outputs["Color"], emit.inputs["Color"])
    nt.links.new(tex.outputs["Alpha"], mix.inputs["Fac"])
    nt.links.new(transp.outputs["BSDF"], mix.inputs[1])
    nt.links.new(emit.outputs["Emission"], mix.inputs[2])
    nt.links.new(mix.outputs["Shader"], out.inputs["Surface"])

    mat.blend_method = "BLEND"
    return mat


def import_reference_plane(json_path):
    """Create a textured plane from a WABF reference-plane ``.json``.

    Returns the created object. Raises ``ValueError`` / ``OSError`` on bad input.
    """
    with open(json_path, "r") as f:
        meta = json.load(f)

    base_dir = os.path.dirname(json_path)
    image_name = meta.get("image")
    if not image_name:
        raise ValueError("JSON has no 'image' field")
    image_path = os.path.join(base_dir, image_name)
    if not os.path.isfile(image_path):
        raise OSError(f"Image not found: {image_path}")

    center = meta["plane_center"]      # [x, y, z] Blender Z-up
    size = meta["plane_size"]          # [size_x, size_y] full extents (meters)
    name = os.path.splitext(os.path.basename(json_path))[0]

    # A 1×1 plane scaled to the full extents — its default UVs map (-x,-y)→image
    # bottom-left and (+x,+y)→image top-right, which matches WABF's exported axis
    # convention (u→+X, image top→+Y), so no UV flip is needed.
    bpy.ops.mesh.primitive_plane_add(size=1.0, location=(center[0], center[1], center[2]))
    obj = bpy.context.active_object
    obj.name = name
    obj.scale = (size[0], size[1], 1.0)

    image = bpy.data.images.load(image_path, check_existing=True)
    obj.data.materials.append(_build_material(name, image))

    # Move it into the dedicated collection (unlink from wherever add() put it).
    coll = _ensure_collection(REFERENCE_COLLECTION)
    for c in list(obj.users_collection):
        c.objects.unlink(obj)
    coll.objects.link(obj)

    # Show the texture in the solid-shaded viewport without entering Material
    # Preview mode.
    obj.active_material.use_nodes = True
    return obj


class CAMERA_SYNC_OT_import_reference_plane(Operator, ImportHelper):
    """Import a WABF reference-plane JSON (+ its PNG) as a scaled textured plane."""

    bl_idname = "camera_sync.import_reference_plane"
    bl_label = "Import WABF Reference"

    filename_ext = ".json"
    filter_glob: StringProperty(default="*.json", options={"HIDDEN"})

    def execute(self, context):
        try:
            obj = import_reference_plane(self.filepath)
        except Exception as e:
            self.report({"ERROR"}, f"Import failed: {e}")
            return {"CANCELLED"}
        self.report({"INFO"}, f"Imported reference plane '{obj.name}'")
        return {"FINISHED"}
