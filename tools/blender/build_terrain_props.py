#!/usr/bin/env python3
"""Sculpts the terrain landforms the asset kits do not provide, and exports .glb.

    .toolchain/blender/blender --background --python tools/blender/build_terrain_props.py

Kenney's kits are built around whole-tile blocks: their mountain is a hexagonal
prism with a cone on top, which reads as a chess piece next to a continuous
landscape. Civilization VI's mountains are sculpted rock — irregular ridged
peaks with snow caps — and neighbouring ones merge into a range rather than
sitting in a row of identical markers.

Each model is built as a **radial height field** rather than by displacing a
sphere. A sphere pushed around by noise folds over itself and produces hooks and
overhangs; a height field cannot, because there is exactly one height per
(angle, radius) sample. So:

  - Sample a polar grid: RINGS rings out to the footprint radius, SEGMENTS
    around.
  - Height at a sample is a peak profile falling off with radius, multiplied by
    a ridge term strongest along a few randomly chosen compass directions. That
    gives a spine and secondary summits instead of a symmetrical cone.
  - Add smaller-scale noise for rock detail, then pin the outermost ring to zero
    so the model always meets the ground with no floating skirt.
  - Colour by height in vertex colours, dark rock through grey to snow. The
    ground shader reads vertex colour, so the snow line costs no texture or UV
    work.

Colours below are written as sRGB, the space you would pick them in, and
converted to linear on the way into the FLOAT_COLOR attribute — Blender stores
that attribute linear, glTF exports it linear, and Godot reads it linear. Skip
the conversion and every value lands roughly one stop too bright: 0.34 sRGB rock
arrives as 0.34 *linear*, which is a pale grey, and a mountain ends up looking
like it is made of snow all the way down.
"""

from __future__ import annotations

import math
import random
import sys
from pathlib import Path

import bmesh
import bpy
from mathutils import Vector

# Blender has no .blend open under --background --python, so "//" resolves to
# the cwd rather than the project. Derive the repo root from this script.
REPO_ROOT = Path(__file__).resolve().parent.parent.parent
OUT_DIR = REPO_ROOT / "assets" / "art" / "models" / "terrain"

RINGS = 7
SEGMENTS = 14

# Cool grey-blue rock, as in the reference. Brown rock reads as desert mesa.
# All values are sRGB; see _to_linear.
ROCK_LOW = Vector((0.38, 0.41, 0.47))
ROCK_MID = Vector((0.52, 0.55, 0.62))
ROCK_HIGH = Vector((0.66, 0.69, 0.75))
SNOW = Vector((0.95, 0.96, 0.98))

GRASS_LOW = Vector((0.32, 0.46, 0.22))
GRASS_HIGH = Vector((0.45, 0.60, 0.28))


def _to_linear(value: float) -> float:
    """sRGB to linear, the transfer function glTF vertex colours are read in."""
    if value <= 0.04045:
        return value / 12.92
    return ((value + 0.055) / 1.055) ** 2.4


def _linear_rgba(colour: Vector) -> tuple[float, float, float, float]:
    return (_to_linear(colour.x), _to_linear(colour.y), _to_linear(colour.z), 1.0)


def clear_scene() -> None:
    bpy.ops.wm.read_factory_settings(use_empty=True)


def rock_colour(t: float, snow_line: float) -> tuple[float, float, float, float]:
    """Rock colour at relative height `t` in 0..1."""
    if t >= snow_line:
        # Ease into the snow so the line is a band, not a hard ring.
        blend = min(1.0, (t - snow_line) / max(1.0 - snow_line, 1e-3) * 2.0)
        base = ROCK_HIGH.lerp(SNOW, blend)
    elif t > 0.5:
        base = ROCK_MID.lerp(ROCK_HIGH, (t - 0.5) / 0.5)
    else:
        base = ROCK_LOW.lerp(ROCK_MID, t / 0.5)
    return _linear_rgba(base)


def grass_colour(t: float, _snow_line: float) -> tuple[float, float, float, float]:
    base = GRASS_LOW.lerp(GRASS_HIGH, min(1.0, t * 1.3))
    return _linear_rgba(base)


def build_landform(
    name: str,
    seed: int,
    height: float = 1.0,
    radius: float = 1.0,
    ridges: int = 2,
    ridge_strength: float = 0.55,
    snow_line: float = 0.62,
    detail: float = 0.16,
    falloff: float = 1.15,
    colour_fn=rock_colour,
) -> bpy.types.Object:
    """One landform as a radial height field, sitting on y = 0."""
    rng = random.Random(seed)

    ridge_dirs = [rng.uniform(0.0, math.tau) for _ in range(max(ridges, 1))]
    ridge_weights = [rng.uniform(0.6, 1.0) for _ in ridge_dirs]
    phase_a, phase_b = rng.uniform(0.0, math.tau), rng.uniform(0.0, math.tau)

    def ridge_at(angle: float) -> float:
        """How strongly this compass direction lies along a ridge, 0..1."""
        best = 0.0
        for direction, weight in zip(ridge_dirs, ridge_weights):
            alignment = math.cos(angle - direction)
            if alignment > 0.0:
                best = max(best, alignment**3.0 * weight)
        return best

    def reach_at(angle: float) -> float:
        """Footprint radius in this direction.

        Ridges *extend the footprint* rather than adding height. Adding height
        was the bug in the first version: a ridge on the innermost ring could
        come out taller than the apex, so the fan from the apex folded back on
        itself and every mountain grew a shark fin. Stretching the base instead
        cannot produce a fold, because height still falls monotonically with
        distance along every direction.
        """
        wobble = 1.0 + math.sin(angle * 3.0 + phase_b) * 0.12
        return radius * wobble * (1.0 + ridge_at(angle) * ridge_strength)

    def sample_height(angle: float, r: float) -> float:
        reach = reach_at(angle)
        if r >= reach:
            return 0.0
        profile = 1.0 - (r / reach) ** falloff

        # Rock detail, scaled by the profile so it never lifts the rim off the
        # ground and leaves a gap under the model.
        noise = (
            math.sin(angle * 5.0 + phase_a) * 0.6
            + math.sin(angle * 11.0 + phase_b) * 0.25
            + math.sin(r * 9.0 + phase_a * 2.0) * 0.3
        )
        return height * profile * (1.0 + noise * detail * profile)

    mesh = bpy.data.meshes.new(name)
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)

    bm = bmesh.new()

    apex = bm.verts.new(Vector((0.0, height, 0.0)))
    loops: list[list] = []
    for ring in range(1, RINGS + 1):
        # Rings follow each direction's own reach, so the outermost always lands
        # exactly on the rim whatever the ridge did to the footprint.
        fraction = ring / RINGS
        loop = []
        for segment in range(SEGMENTS):
            angle = math.tau * segment / SEGMENTS
            r = reach_at(angle) * fraction
            y = 0.0 if ring == RINGS else sample_height(angle, r)
            loop.append(
                bm.verts.new(Vector((math.cos(angle) * r, y, math.sin(angle) * r)))
            )
        loops.append(loop)

    bm.verts.ensure_lookup_table()

    first = loops[0]
    for segment in range(SEGMENTS):
        bm.faces.new((apex, first[segment], first[(segment + 1) % SEGMENTS]))

    for index in range(len(loops) - 1):
        inner, outer = loops[index], loops[index + 1]
        for segment in range(SEGMENTS):
            nxt = (segment + 1) % SEGMENTS
            bm.faces.new((inner[segment], outer[segment], outer[nxt], inner[nxt]))

    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(mesh)
    bm.free()

    # Flat shading: smooth normals on low-poly rock lose the facets that make it
    # read as stone at all.
    for polygon in mesh.polygons:
        polygon.use_smooth = False

    tallest = max((v.co.y for v in mesh.vertices), default=1.0) or 1.0
    layer = mesh.color_attributes.new(name="Color", type="FLOAT_COLOR", domain="CORNER")
    for loop_index, loop in enumerate(mesh.loops):
        y = mesh.vertices[loop.vertex_index].co.y
        layer.data[loop_index].color = colour_fn(y / tallest, snow_line)

    return obj


def export(obj: bpy.types.Object, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.export_scene.gltf(
        filepath=str(path),
        export_format="GLB",
        use_selection=True,
        export_apply=True,
        export_yup=True,
        export_materials="EXPORT",
    )


MODELS = {
    "mtn_peak_a": dict(seed=11, height=1.10, radius=1.04, ridges=2, snow_line=0.76),
    "mtn_peak_b": dict(seed=27, height=1.28, radius=0.98, ridges=3, snow_line=0.72),
    "mtn_peak_c": dict(seed=43, height=0.95, radius=1.10, ridges=2, snow_line=0.80),
    "mtn_ridge_a": dict(
        seed=61, height=0.86, radius=1.16, ridges=1, ridge_strength=0.85, snow_line=0.84
    ),
    "mtn_ridge_b": dict(
        seed=79, height=0.98, radius=1.10, ridges=2, ridge_strength=0.75, snow_line=0.80
    ),
    # Hills: same sculptor, low and green, snow line pushed off the top.
    "hill_a": dict(
        seed=97, height=0.34, radius=1.05, ridges=1, ridge_strength=0.35,
        snow_line=2.0, detail=0.10, falloff=2.0, colour_fn=grass_colour,
    ),
    "hill_b": dict(
        seed=113, height=0.40, radius=0.98, ridges=2, ridge_strength=0.30,
        snow_line=2.0, detail=0.12, falloff=2.0, colour_fn=grass_colour,
    ),
    # Shoreline rock, from the coastlines in the reference shots.
    "rock_shore_a": dict(
        seed=131, height=0.62, radius=0.46, ridges=2, snow_line=2.0, detail=0.30
    ),
    "rock_shore_b": dict(
        seed=149, height=0.44, radius=0.38, ridges=1, snow_line=2.0, detail=0.34
    ),
}


def main() -> int:
    clear_scene()
    for name, kwargs in MODELS.items():
        obj = build_landform(name, **kwargs)
        export(obj, OUT_DIR / f"{name}.glb")
        bpy.data.objects.remove(obj, do_unlink=True)
    print(f"[build_terrain_props] exported {len(MODELS)} models to {OUT_DIR}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
