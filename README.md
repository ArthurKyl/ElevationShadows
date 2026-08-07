# Elevation Shadows

Sun-aware terrain shadows for [Dungeondraft](https://dungeondraft.net/),
cast from your cliff and wall paths. Draw your terrain the way you already
do — nested contour paths on one level — tag them with a height in feet, and
the mod computes physically accurate shadows for the whole map: correct
lengths from height and sun angle, soft penumbra that widens with distance,
multi-tier stacking, and shadows that respect Dungeondraft's layers and
Bring to front / Send to back.

Built for TTRPG battlemaps: heights are entered in **feet** (one grid square
= 5 ft), and when someone asks how long a 20 ft cliff's shadow should be,
the answer on screen is the physically correct one — `height / tan(sun
altitude)`. Want drama? Lower the sun. The numbers stay honest.

## Features

- **One global sun** (direction + height), synced both ways with
  Dungeondraft's native roof sun so cliffs and roofs agree.
- **Physically accurate lengths** with live readouts: the path panel shows
  "Casts 34 ft of shadow (6.9 squares)" for the selected cliff, and the sun
  panel shows the current shadow-to-wall-height ratio.
- **Real penumbra.** Diffusion models the sun's angular size: low = crisp
  desert light, high = soft overcast. Blur widens with distance from the
  cliff, like the real thing — no fake gradient tricks.
- **Terrain steps and free-standing walls.** A path is either a contour
  (one side uphill: Side A/B) or a **Wall** — only the path's strip is
  raised, both sides low. A closed circle of wall shades its own interior
  on the sun-facing arc: instant crater.
- **Multi-tier aware.** Nested contours stack (three 5 ft contours = a
  15 ft summit), shadows fall correctly across other tiers, and overlapping
  shadows never double-darken.
- **Respects your layering.** A layer-4 path's shadow darkens layer-2 cliff
  art. Objects escape or receive a shadow with Dungeondraft's own
  **Bring to front / Send to back** buttons — per object, saved with the
  map. Cliff art hides the shadow's leading edge under its real bumpy
  texture edge (per-path *Art above shadow* toggle + *Shadow inset* for
  fine-tuning).
- **Export-ready.** Shadows land in PNG and Universal VTT exports exactly
  as layered in the editor, and the shadow textures re-bake at double
  resolution while the export dialog is open so a 100 px/square export
  stays crisp.
- Live / Export-only / Off modes, and everything is baked — panning and
  zooming cost nothing.

## Installation

Copy the `ElevationShadows` folder into your Dungeondraft `mods` directory
and enable **Elevation Shadows** in the Mods menu. Built and tested against
Dungeondraft 1.2.0.1.

## Workflow

1. Open the **Elevation Shadows** tool (Effects category). Set the sun's
   Direction and Sun height — or leave *Follow DD roof sun* on and use the
   roof tool's sun you already know.
2. Draw your cliff as a normal path on whatever layer it belongs to.
3. Select it, toggle **Elevation Shadow**, and pick the side: **Side A/B**
   for a terrain step (which side is uphill), or **Wall (both)** for a
   free-standing wall. Flip once if the fill lands on the wrong side.
4. Set **Drop height** in feet (slider to 120 ft; type into the box for up
   to 240 ft). The readout tells you what it casts at the current sun.
5. Objects: anything on the caster's layer starts lit. **Send to back** to
   push it under the shadow, **Bring to front** to lift it out.
6. Export as usual — PNG and Universal VTT both include the shadows.

### Per-path settings

| Setting | What it does |
|---|---|
| Elevation Shadow | This path casts (and raises the terrain on its uphill side). |
| Side A / Side B / Wall (both) | Which side is uphill — or a free-standing wall, raised only along the path with both sides low. |
| Drop height (ft) | How far the ground drops. Drives shadow length physically. |
| Art above shadow | The path's artwork draws over its own layer's shadow, so the texture's real edge hides where the shadow starts. On by default for casters. |
| Shadow inset | Fine-tune (in px) how far the shadow tucks under the art's edge. |

### Global settings

| Setting | What it does |
|---|---|
| Off / Export only / Live | Master mode. Export only keeps the editor light and injects shadows only while exporting. |
| Direction | Compass direction the light comes from. Syncs with the roof sun. |
| Sun height | Sun altitude. Low sun = long shadows. The realism note updates live. |
| Strength | How dark shadows are. |
| Diffusion | The sun's angular size: edge softness, widening with distance. |
| Show elevation field | Debug overlay of the computed terrain heights. |

## How it works (short version)

Contour paths are treated as topographic lines and rasterised into a height
field — elevation at any point is the sum of every contour whose uphill side
contains it. A per-pixel shader then marches from each point toward the sun
through that field, computing the horizon angle against the sun's angular
extent. The result is baked to textures (one per Dungeondraft layer in use,
placed so layer ordering works out) and re-baked only when something
changes. Per-path config is stored in the map file via Dungeondraft's mod
data, so everything survives save/reload.
