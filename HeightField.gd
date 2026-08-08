#########################################################################################################
##
## HEIGHT FIELD — rasterise contour paths into an elevation texture
##
#########################################################################################################
# Your cliff contours are topographic contour lines: each one separates lower
# ground from higher ground, and they nest. So elevation at a point is just the
# sum of the heights of every contour whose uphill side contains it — which is
# an additive polygon fill, not a computation.
#
# Once that texture exists, shadowing is a per-pixel march through it, which is
# continuous by construction. That is what kills the whole family of artifacts
# the per-point mesh version kept producing (visible clip lines, pinholes,
# shadow leaking inside a ridge) — there are no per-point decisions left to be
# inconsistent with each other.
#
# THIS MODULE ONLY BUILDS AND SHOWS THE FIELD. The march comes next, once the
# fill is confirmed correct by eye.
#
# Closing an open contour into a fillable region:
#   - Endpoints at//past the map edge  -> extend to the boundary, then walk the
#     map rectangle's corners around the uphill side.
#   - Endpoints inside the map         -> close with a direct chord. If uphill
#     turns out to be OUTSIDE that loop, fill the map rect minus the loop.
# Which side is uphill comes from the per-path Side A/B/Both flag, never inferred.

var global
var core = null
var sun_settings = null
var path_tagging = null

# Height is stored in a colour channel as tiers/HEIGHT_DIVISOR, so up to this
# many tiers (grid squares of height) stack per layer slot before the encoding
# clips. 64 = 320ft of headroom at 5ft/square — needed since the UI allows
# single cliffs up to 240ft (48 tiers). Precision is not a concern: the render
# target's channels are 10-bit, so even at /64 there are ~16 encoding steps per
# tier, far finer than the level_blend smoothing that reads the field.
const HEIGHT_DIVISOR = 64.0

# Cap on the render target's longest side. The field does not need full map
# resolution — the march samples it, and shadow penumbra hides the difference.
# During EXPORT the cap doubles (Core toggles `export_boost` around the export
# window): a typical 100 px/square export of this 45x45 map is ~4500 px, and
# upscaling a 2048 bake 2.2x visibly softens the shadow's contact edge against
# crisp art. The boost also sharpens the art MASK, which defines that edge.
const MAX_DIM = 2048.0
const EXPORT_MAX_DIM = 4096.0
var export_boost = false

func _cap_dim() -> float:
	return EXPORT_MAX_DIM if export_boost else MAX_DIM

const CONTAINER_NAME = "ElevationShadowsHeightField"
const DEBUG_SPRITE_NAME = "ElevationShadowsHeightDebug"

# ART FOOTPRINT — "only where opacity is 100%". Not 1.0: the field rasterises at
# ~1/6 world scale, so a bilinear tap anywhere near the art's soft edge never
# returns an exact 1.0 even over fully opaque source texels. 0.95 keeps the
# opaque core and drops every semi-transparent edge, which is the whole point:
# no partial-height ground, hence no unartworked mini-steps casting their own
# shadows. See ArtFootprint.shader.
const ART_ALPHA_THRESHOLD = 0.95

# "Something stands here" — half a tier, in channel units. Used by the
# art-over-fill ridge probe to decide whether a texel carries fill / footprint at
# all; the smallest usable height is a whole tier, so half of one is well clear
# of both zero and the 10-bit rounding of the render target.
const FILL_EPS = 0.5 / HEIGHT_DIVISOR

# ---------------------------------------------------------------------------
# PER-LAYER SLOTS
# ---------------------------------------------------------------------------
# There is one shadow node (a ghost Prop inside Level.Objects) per distinct
# caster LAYER, each at z = its own layer: over every lower layer's artwork (so
# a layer-400 caster's shadow darkens a layer-200 cliff) and over untiered z-0
# content, while same-layer objects are ordered against it with DD's own Bring
# to front / Send to back, and same-layer path art opts out via the per-layer
# "Art above shadow" mask. See ShadowRenderer for the full placement story.
#
# A caster's layer is its `z_index` — DD's Layer dropdown writes ZIndex directly
# (PathTool::SetLayer). NOTE: the layer and the mod's elevation TIER are wholly
# independent concepts that merely correlate on maps where taller cliffs were put
# on higher layers. Grouping keys off z_index, because z_index is what decides
# placement.
#
# For each sprite to draw only the shadow ITS layer owns, the shader has to know
# which layer produced each bit of elevation. So heights are not all summed into
# red; each layer group gets its own colour channel:
#
#     chain 0 -> R = slot 0, G = slot 1, B = slot 2
#     chain 1 -> R = slot 3, G = slot 4, B = slot 5   (only built when needed)
#
# Total elevation is the sum of every channel, so the march still reads the FULL
# terrain height for the receiving ground and shadow LENGTHS stay correct where a
# shadow falls across another layer's tiers. Alpha is never used for any of this:
# a USAGE_2D render target is RGB10_A2, and alpha there has only two bits.
const SLOTS_PER_CHAIN = 3
const MAX_SLOTS = 6

# [{ "layer": float, "slot": int, "casters": [Line2D] }], ascending by layer.
var _groups = []
# One entry per raster chain:
#   {"raster":Viewport, "root":Node2D, "blur_h":Viewport, "blur_v":Viewport,
#    "spr_h":Sprite, "spr_v":Sprite}
# The march reads "blur_v" — see HeightSmooth.shader for why smoothing is
# mandatory rather than cosmetic.
var _chains = []
# One raster viewport per chain holding the PER-LAYER ART MASK: the artwork of
# paths flagged "Art above shadow", channel-packed like the height field (R,G,B
# = the chain's three slots). No blur — the mask must follow the art's alpha
# edge exactly. [{"vp":Viewport, "root":Node2D}]
var _mask_chains = []
# The SHADOW BLOCKER raster: strips of every "Stops outside shadows" path/
# wall, rendered white into one binary target (field size, no blur). The march
# stops when a sun-ray crosses it, so occluders beyond never darken the near
# side. {"vp":Viewport, "root":Node2D} or null.
var _blocker = null
# ONE-SIDED WALLS: per slot, the regions where this group's shadow must be
# ERASED so a wall casts on one side only. Rebuilt with the field; consumed by
# ShadowRenderer, which draws them black into the group's beam mask (the march
# multiplies its output by the mask, so the casting side's penumbra survives
# untouched while the suppressed side is exactly clean).
# slot -> [entry], entry keys: nid, cast_side (0/1), closed, mode
# ("interior"|"band"), pts, half, h_tiers, interior_meshes, interior_area,
# outward_sign (band mode only). See _register_side_suppressor for semantics.
var _side_suppress = {}
var _smooth_shader = null
var _mask_shader = null
var _artfoot_shader = null
# Per slot, the tallest path that contributed an ART FOOTPRINT. Bounds the
# footprint target's own additive overlap when two same-layer paths' artwork
# crosses (HeightSmooth's `art_clamp`), and is read back by the probes so they
# combine exactly the way the blur pass does.
var _slot_art_max = []
var _debug_sprites = []
var _map_rect = null      # true canvas bounds, for "is this endpoint at the edge"
var _raster_rect = null   # render-target bounds; >= _map_rect so nothing is clipped
var _vp_scale = 1.0
# Tallest stacked elevation actually MEASURED in the field, read back a frame
# after each rebuild and kept across rebuilds. The march's early exit is bounded
# by it, and the analytic bound (every caster's drop summed) can be several times
# too large — which used to be harmless because a single pass could always exit on
# its running maximum, but per-layer passes cannot (see ElevationShadow.shader).
var _observed_max_tiers = 0.0
var _viewport_count = 0

func outputlog(msg, level = 0):
	if core != null:
		core.outputlog("[Height] " + str(msg), level)

#########################################################################################################
## MAP BOUNDS
#########################################################################################################

func initialise():
	_smooth_shader = ResourceLoader.load(global.Root + "shaders/HeightSmooth.shader", "Shader", true)
	if _smooth_shader == null:
		outputlog("WARNING: HeightSmooth.shader failed to load — field will be unsmoothed", 0)
	else:
		outputlog("smoothing shader loaded", 0)
	_mask_shader = ResourceLoader.load(global.Root + "shaders/MaskChannel.shader", "Shader", true)
	if _mask_shader == null:
		outputlog("WARNING: MaskChannel.shader failed to load — no 'Art above shadow'", 0)
	_artfoot_shader = ResourceLoader.load(global.Root + "shaders/ArtFootprint.shader", "Shader", true)
	if _artfoot_shader == null:
		outputlog("WARNING: ArtFootprint.shader failed to load — contour art will not raise ground", 0)

func _resolve_map_rect():
	if global == null or global.World == null:
		return null
	var inst = global.World.get("Instance")
	if inst == null:
		outputlog("World.Instance unavailable", 0)
		return null

	var r = inst.get("WorldRect")
	if r is Rect2 and r.size.x > 1.0 and r.size.y > 1.0:
		outputlog("map rect from WorldRect: %s" % str(r), 0)
		return r

	var w = inst.get("MapWidth")
	var h = inst.get("MapHeight")
	var ts = inst.get("TileSize")
	if w != null and h != null and ts != null:
		var rect = Rect2(0.0, 0.0, float(w) * float(ts), float(h) * float(ts))
		outputlog("map rect from MapWidth/MapHeight/TileSize (%s x %s @ %s): %s" % [
			str(w), str(h), str(ts), str(rect)], 0)
		return rect

	outputlog("could not determine map bounds", 0)
	return null

# Render-target bounds: the canvas, expanded to contain every caster.
#
# WorldRect starts at (0,0) but paths can sit outside it — this map has contours
# reaching x = -392 and y = 11876. Anything beyond the render target is simply
# lost, which showed up as missing shadow along the leftmost stretch of wall.
# Growth is capped so one stray far-off path can't balloon the target and cost
# resolution everywhere else.
func _compute_raster_rect() -> Rect2:
	var rect = _map_rect
	var tier_px = float(sun_settings.get_sun().get("tier_px", 256.0))
	for path in path_tagging.get_caster_nodes():
		for p in _world_points(path):
			rect = rect.expand(p)
	for node in path_tagging.get_blocker_nodes():
		for p in _world_points(node):
			rect = rect.expand(p)
	# Cap expansion at two tiers beyond the canvas on every side.
	rect = rect.clip(_map_rect.grow(tier_px * 2.0))
	# Small margin so boundary-snapped endpoints stay inside the target — and, for
	# the ART FOOTPRINT, enough room for the widest artwork to reach half its
	# width past its own spine. The rect only ever expanded to caster POINTS, so a
	# contour drawn near the canvas edge would have its footprint sliced off at the
	# target boundary while the rest of the map got one, leaving the old hard band
	# alive along the edges only.
	var margin = 48.0
	for path in path_tagging.get_caster_nodes():
		if not _has_art_footprint(path):
			continue
		margin = max(margin, _art_half_width(path))
	rect = rect.grow(margin)
	if margin > 48.0:
		outputlog("raster margin %.0f px (widest contour art half-width)" % margin, 1)
	if rect.size != _map_rect.size:
		outputlog("raster rect %s (canvas was %s) — expanded to cover off-canvas contours" % [
			str(rect), str(_map_rect)], 0)
	return rect

#########################################################################################################
## CONTOUR -> POLYGON
#########################################################################################################

# Geometry.* expects PoolVector2Array, not a plain Array. Passing an Array
# either errors or silently misbehaves depending on the call, so every polygon
# goes through here before it reaches Geometry.
func _to_packed(arr) -> PoolVector2Array:
	if arr is PoolVector2Array:
		return arr
	var packed = PoolVector2Array()
	for p in arr:
		packed.append(p)
	return packed

func _world_points(path) -> PoolVector2Array:
	var out = PoolVector2Array()
	# Paths are Line2D (`points`); DD walls are Node2D with a C# `Points`
	# property (their visible art lives in child Line2D segments).
	var src = path.get("points")
	if src == null:
		src = path.get("Points")
	if src == null:
		return out
	for p in src:
		out.append(path.to_global(p))
	# Canonical ordering so Side A means the same geometric side regardless of
	# which end the user drew from.
	return core.orient_points(out)

func _is_closed(path) -> bool:
	for prop in ["loop", "Loop", "closed", "Closed", "IsLoop"]:
		var val = path.get(prop)
		if val is bool and val:
			return true
	return false

# A test point on the UPHILL side of the contour.
#
# CONVENTION, and the source of a nasty inversion bug — read before editing:
# ShadowBuilder treats Side A as the side the shadow FALLS on, which is the
# DOWNHILL side, and that is what the user picks by eye in the Side button.
# Uphill is therefore the OPPOSITE of the shadow side. Reusing ShadowBuilder's
# normal directly here filled every contour on the wrong side, and when uphill
# landed outside a closed loop it fell through to _rect_minus and greyed out
# almost the whole map.
const UPHILL_SAMPLES = 24
const UPHILL_OFFSET = 288.0

# Sample points spread along the contour, each stepped off to the UPHILL side.
#
# A single midpoint sample was not good enough: on a branching, folded contour it
# lands on the wrong side or inside a fold often enough that closure selection
# failed for half the paths, which then fell back to filling the whole map.
# Voting over many samples tolerates individual bad ones.
func _uphill_sample_points(pts: PoolVector2Array, side: int) -> Array:
	var count = pts.size()
	var samples = []
	if count < 2:
		return samples
	var step = max(1, int(count / UPHILL_SAMPLES))
	var i = 1
	while i < count:
		var d = pts[i] - pts[i - 1]
		if d.length() > 0.01:
			d = d.normalized()
			# ShadowBuilder's Side A normal is the DOWNHILL direction, so uphill
			# is its negation. See the convention note in that module.
			var downhill = Vector2(-d.y, d.x)
			if side == 1:
				downhill = -downhill
			var p = pts[i] + (-downhill) * UPHILL_OFFSET
			# Samples outside the map can't discriminate between candidates.
			if _map_rect == null or _map_rect.has_point(p):
				samples.append(p)
		i += step
	return samples

# WALL MODE (Side = "Wall (both)"): the path is a free-standing wall. The strip
# under the drawn artwork — path width, shrunk by the per-path Shadow inset so
# the elevation edge sits at the art's visible edge rather than the transparent
# margin — is raised by the drop height, and BOTH sides stay low.
#
# A closed wall's strip is a RING: Clipper returns its outer boundary plus a
# hole (the enclosed ground — the crater floor, which must stay low), and
# triangulate_polygon cannot handle holes. So each hole is resolved by
# splitting the piece vertically through the hole's centre and subtracting the
# hole from each half; the results are simple polygons. Open paths whose round
# end caps overlap (a circle drawn without closing the loop) produce the same
# ring-with-hole shape, so this handles them identically.
#
# `ring_out`: pass a Dictionary to receive the strip's byproducts —
#   "holes": the CW ring-hole polygons (the ground a closed wall encloses),
#   "half":  the final strip half-width in world px (after inset + blur floor).
# The one-sided-wall suppression needs both: the holes ARE the interior region,
# and the half-width pads the suppression band. Callers that don't care pass
# nothing.
func _path_strip_polygons(path, inset: float, cut_portals: bool = true, ring_out = null) -> Array:
	var pts = _world_points(path)
	if pts.size() < 2:
		return []
	var raw_width = path.get("width")
	if raw_width == null:
		# Walls have no width of their own; their child Line2D segments do.
		for line in _art_lines(path):
			raw_width = line.width
			break
	var half = (float(raw_width) * 0.5) if raw_width != null else 32.0
	half = max(4.0, half - max(0.0, inset))
	# THE STRIP MUST SURVIVE THE BLUR. The march reads the SMOOTHED field, and
	# a strip much narrower than the Gaussian kernel nearly vanishes from it.
	# This wall's art was ~18 px, the strip came out 8 px = 1.35 field texels,
	# and at sigma = level_blend = 4 texels the blurred peak kept ~10-14% — a
	# 2.8-tier wall marched as ~0.39 tiers and its shadow collapsed to ~10% of
	# its length, while every probe (which reads the RAW raster) kept reporting
	# full height. Two cold-read agents independently root-caused and verified
	# this numerically (2026-08-07). Floor the half-width at 2*sigma texels
	# (strip = 4*sigma keeps ~95% of its height); the cost is the elevation
	# footprint being wider than thin art, which shows as a small lit margin
	# around the wall before its shadow starts.
	var blend = float(sun_settings.get_sun().get("level_blend", 2.0))
	var min_half = min(2.0 * max(0.35, blend) / max(0.0001, _vp_scale), 128.0)
	if half < min_half:
		outputlog("path %s: strip half-width %.0f px below blur-safe %.0f px — widening" % [
			str(core.get_node_id(path)), half, min_half], 1)
		half = min_half
	var end_type = Geometry.END_JOINED if _is_closed(path) else Geometry.END_ROUND
	var strips = Geometry.offset_polyline_2d(_to_packed(pts), half, Geometry.JOIN_ROUND, end_type)

	var solids = []
	var holes = []
	for p in strips:
		if p.size() < 3:
			continue
		if Geometry.is_polygon_clockwise(p):
			holes.append(p)
		else:
			solids.append(p)

	if ring_out is Dictionary:
		ring_out["holes"] = holes
		ring_out["half"] = half

	solids = _subtract_holes(solids, holes)

	# Portal gaps are cut ONLY for the BLOCKER raster (and only for wall-strip
	# casters: wall nodes on any side, paths in Wall mode — on a Side A/B
	# PATH portals must have zero effect). The ELEVATION
	# strip stays SOLID across open portals: the march bakes the full wall
	# shadow and ShadowRenderer's multiplicative beam masks carve the
	# opening's light out of the BAKE. Cutting the elevation instead (the
	# first scheme) left a soft-edged light corridor that additively-rebuilt
	# quads could never meet without seams or double-darkening — the bake
	# measured red at 1.00 when the march can emit at most `opacity`.
	if cut_portals:
		solids = _cut_open_portals(path, solids, half)

	if solids.size() == 0:
		outputlog("path %s: wall strip produced no fillable region" % str(core.get_node_id(path)), 0)
	elif holes.size() > 0:
		outputlog("path %s: wall ring with %d enclosed region(s) -> %d simple piece(s)" % [
			str(core.get_node_id(path)), holes.size(), solids.size()], 1)
	return solids

# Sun through open doors. A DD portal carries the map's own open/shut state:
# Portal.Closed is the portal-tool toggle DD's lighting system reads (saved as
# 'closed', drives the portal's LightOccluder). So the elevation honours the
# same truth — an OPEN portal cuts its span out of the wall's raised strip and
# the shadow breaks exactly where light would pass; a closed one leaves the
# wall solid. Portal.Begin/End are world-space endpoints of the portal along
# the wall (global_position ± direction * radius, verified in the assembly).
# The cut rectangle overhangs the strip on both sides, so it always bisects a
# piece rather than punching a hole (which could not be triangulated).
# The OPEN portals of a wall: WallID children plus proximity-adopted
# freestanding ones, filtered through PathTagging.is_portal_open (the mod's
# "Open for sunlight" toggle, falling back to DD's Closed flag). ONE
# collection shared by the blocker gap cutter and ShadowRenderer's beam-mask
# builder, so blocker gaps and light beams can never disagree about which
# doors exist (the earlier split meant an unsnapped door got a gap but no
# beam). Via PathTagging.get_wall_portals — Wall.Portals itself is a C#
# List<T> that Godot's bridge cannot marshal (get() returns null, silently).
func get_open_wall_portals(path, half: float = 64.0) -> Array:
	var portals = path_tagging.get_wall_portals(path, false)
	# Portals without a living WallID (freestanding, or their wall was
	# redrawn) are adopted by proximity: DD only writes WallID when the portal
	# snapped onto the wall at placement, and a door dropped onto the art
	# without snapping should still let light through.
	var pts = _world_points(path)
	if pts.size() >= 2:
		for portal in path_tagging.get_unattached_portals():
			var radius = portal.get("Radius")
			var reach = half + (float(radius) if radius != null else 64.0)
			var dist = _dist_to_polyline(pts, portal.global_position)
			if dist <= reach:
				portals.append(portal)
				outputlog("path %s: unattached portal adopted by proximity (%.0f px from wall line)" % [
					str(core.get_node_id(path)), dist], 1)
	var out = []
	for portal in portals:
		if portal == null or not is_instance_valid(portal):
			continue
		if path_tagging.is_portal_open(portal):
			out.append(portal)
	return out

# Cut each open portal's span out of the BLOCKER strip, so outside shadows
# spill through open doors ("Stops outside shadows" must not stop them at a
# doorway).
func _cut_open_portals(path, solids: Array, half: float) -> Array:
	var cut = 0
	for portal in get_open_wall_portals(path, half):
		var a = portal.get("Begin")
		var b = portal.get("End")
		if not (a is Vector2 and b is Vector2):
			continue
		var d = b - a
		if d.length() < 0.5:
			continue
		var dirn = d.normalized()
		var n = Vector2(-dirn.y, dirn.x) * (half + 32.0)
		var gap = PoolVector2Array([a - n, b - n, b + n, a + n])
		var next = []
		for piece in solids:
			for c in Geometry.clip_polygons_2d(_to_packed(piece), gap):
				if c.size() >= 3 and not Geometry.is_polygon_clockwise(c):
					next.append(c)
		solids = next
		cut += 1
	if cut > 0:
		outputlog("path %s: %d open portal(s) cut from the blocker strip" % [
			str(core.get_node_id(path)), cut], 0)
	return solids

# Shortest distance from a point to any segment of a polyline.
func _dist_to_polyline(pts: PoolVector2Array, p: Vector2) -> float:
	var best = 1e12
	for i in range(pts.size() - 1):
		var closest = Geometry.get_closest_point_to_segment_2d(p, pts[i], pts[i + 1])
		var d = closest.distance_to(p)
		if d < best:
			best = d
	return best

#########################################################################################################
## ONE-SIDED WALLS — side suppression regions
#########################################################################################################
# A wall node on Side A/B casts on ONE side only. The elevation strip cannot
# express that (a raised strip shades whichever side faces away from the sun),
# so the OFF side is erased from the BAKE instead: these regions are drawn
# BLACK into the group's beam-mask viewport (ShadowRenderer), and the march
# multiplies its output by the mask. The casting side keeps its full soft
# penumbra (mask = 1 there); the suppressed side is exactly clean; the hard
# mask edge sits on the wall centerline / strip edge, hidden under the art.
#
# Region semantics:
#   * CLOSED wall — the strip ring encloses ground (detected by the ring
#     HOLES, which also catches a circle drawn without closing the loop):
#       Side A = casts OUTSIDE. The WHOLE interior is suppressed — the lit-
#         house case: nothing from this layer may darken the floor plan, other
#         same-layer walls' spill included ("the interior stays clean").
#       Side B = casts INSIDE (courtyard/crater). The exterior is suppressed
#         as a BAND around the wall, not the whole map — see below.
#   * OPEN wall — Side A/B name the same geometric side a contour's Side A/B
#     shadow falls on (pts are canonicalised by Core.orient_points; Side A =
#     the (-dy,dx) side). The OPPOSITE side is suppressed as a BAND. The
#     contour closure machinery is NOT reused here: for a straight interior
#     wall its chord closure degenerates to a zero-area sliver vs the whole
#     map, and "whole map" would suppress the casting side too.
#
# Why a BAND and not the whole half-region: the mask multiplies the ENTIRE
# layer group's bake, so black also erases OTHER same-layer casters' shadow
# there (all walls share layer 600). Desired inside a closed interior;
# disastrous map-wide (one Side-B house would erase every other building's
# shadow on the whole exterior). The band is sized in ShadowRenderer to THIS
# wall's maximum shadow reach at the current sun (h/tan_lo + strip + blur
# margin, rebuilt with the uniforms so altitude changes track live) — exactly
# the area this wall could ever shade, so collateral is minimal. Accepted
# limit: another same-layer shadow crossing the band's outer edge shows a
# hard cut there.
#
# Accepted limit (degenerate): a wall that self-encloses only partially (a
# lasso — hole plus an open tail) is treated as closed, so the tail casts on
# both sides.

func _register_side_suppressor(slot: int, path, side: int, ring: Dictionary, height_tiers: float):
	var pts = _world_points(path)
	if pts.size() < 2:
		return
	var holes = ring.get("holes", [])
	var closed = holes.size() > 0
	var nid = str(core.get_node_id(path))
	var entry = {
		"nid": nid,
		"cast_side": side,
		"closed": closed,
		"mode": "band",
		"pts": pts,
		"half": float(ring.get("half", 32.0)),
		"h_tiers": height_tiers,
		"interior_meshes": [],
		"interior_area": 0.0,
	}
	if closed and side == 0:
		entry["mode"] = "interior"
		for hole in holes:
			# Clipper holes are CW; reverse so triangulation/cleaning treats
			# them as solids.
			var ccw = PoolVector2Array(hole)
			ccw.invert()
			var mesh = _make_polygon_mesh(ccw, Color(0, 0, 0, 1))
			if mesh != null:
				entry["interior_meshes"].append(mesh)
				entry["interior_area"] += abs(_poly_area(hole))
		if entry["interior_meshes"].size() == 0:
			outputlog("  slot %d wall %s: one-sided but no interior mesh could be built — casting BOTH sides" % [
				slot, nid], 0)
			return
		outputlog("  slot %d wall %s one-sided (Side A = casts OUTSIDE): interior suppressed, %d piece(s), area=%.1f%% of map" % [
			slot, nid, entry["interior_meshes"].size(),
			100.0 * entry["interior_area"] / _map_area()], 0)
	elif closed:
		# Outward per-segment normal: for our shoelace convention a POSITIVE
		# signed area means n = (-dy,dx) points INTO the loop (verified with a
		# y-down unit square), so outward is its negation.
		entry["outward_sign"] = -1.0 if _poly_area(pts) > 0.0 else 1.0
		outputlog("  slot %d wall %s one-sided (Side B = casts INSIDE): exterior band suppressed (sized by sun — see [Render] side suppression)" % [
			slot, nid], 0)
	else:
		# Open wall: contour convention — Side A's shadow side is (-dy,dx), so
		# suppress the other side (sign -1); Side B mirrors.
		entry["outward_sign"] = -1.0 if side == 0 else 1.0
		outputlog("  slot %d wall %s one-sided (casts %s only): opposite band suppressed (sized by sun — see [Render] side suppression)" % [
			slot, nid, "Side A" if side == 0 else "Side B"], 0)
	if not _side_suppress.has(slot):
		_side_suppress[slot] = []
	_side_suppress[slot].append(entry)

# The suppression entries of one layer group (empty array when none).
func get_side_suppressors(slot: int) -> Array:
	return _side_suppress.get(slot, [])

func get_map_area() -> float:
	return _map_area()

# The suppression BAND for one entry: every point within `dist` of the wall
# centerline on the suppressed side, as raw triangles (per-segment swept
# rectangles + joint fans + end extensions past open tips, so the round end
# caps' wrap-around shadow dies too). Overlap between triangles is harmless —
# they render BLACK into a multiplicative mask, and 0*0 = 0 — which is what
# makes this robust with zero Clipper work: no unions, no self-intersection
# cleanup, no hole subtraction. Returns {"mesh": ArrayMesh, "area": float}
# (area sums the triangles, so overlaps double-count — logged with a ~).
func build_suppress_band_mesh(entry: Dictionary, dist: float) -> Dictionary:
	var pts: PoolVector2Array = entry["pts"]
	var nsign = float(entry.get("outward_sign", 1.0))
	var closed = bool(entry["closed"])
	var n_pts = pts.size()
	if n_pts < 2:
		return {}
	var segs = []
	var seg_count = n_pts if closed else n_pts - 1
	for i in range(seg_count):
		var a = pts[i]
		var b = pts[(i + 1) % n_pts]
		var dvec = b - a
		if dvec.length() < 0.5:
			continue
		var dirn = dvec.normalized()
		segs.append({"a": a, "b": b, "t": dirn,
			"n": Vector2(-dirn.y, dirn.x) * nsign})
	if segs.size() == 0:
		return {}

	# Plain Array accumulator: PoolVector2Array is copy-on-write across calls,
	# so appending inside helpers would not reach the caller.
	var tris = []
	for s in segs:
		var far_a = s["a"] + s["n"] * dist
		var far_b = s["b"] + s["n"] * dist
		_band_tri(tris, s["a"], s["b"], far_b)
		_band_tri(tris, s["a"], far_b, far_a)
	# Joint fans fill the wedge gap where consecutive segments turn away from
	# the band (and overlap harmlessly where they turn into it).
	var wedge_count = segs.size() if closed else segs.size() - 1
	for i in range(wedge_count):
		var s0 = segs[i]
		var s1 = segs[(i + 1) % segs.size()]
		_band_fan(tris, s1["a"], s0["n"], s1["n"], dist)
	if not closed:
		# Extend past the tips so the end caps' radial shadow is covered on
		# the suppressed side (the casting side's wrap-around survives).
		var first = segs[0]
		var back = first["a"] - first["t"] * dist
		_band_tri(tris, first["a"], back, back + first["n"] * dist)
		_band_tri(tris, first["a"], back + first["n"] * dist, first["a"] + first["n"] * dist)
		var last = segs[segs.size() - 1]
		var fwd = last["b"] + last["t"] * dist
		_band_tri(tris, last["b"], fwd, fwd + last["n"] * dist)
		_band_tri(tris, last["b"], fwd + last["n"] * dist, last["b"] + last["n"] * dist)

	var verts = PoolVector2Array()
	var colors = PoolColorArray()
	var black = Color(0, 0, 0, 1)
	var area = 0.0
	var i = 0
	while i < tris.size():
		var pa = tris[i]
		var pb = tris[i + 1]
		var pc = tris[i + 2]
		area += abs((pb - pa).cross(pc - pa)) * 0.5
		verts.append(pa)
		verts.append(pb)
		verts.append(pc)
		colors.append(black)
		colors.append(black)
		colors.append(black)
		i += 3

	var arrays = []
	arrays.resize(ArrayMesh.ARRAY_MAX)
	arrays[ArrayMesh.ARRAY_VERTEX] = verts
	arrays[ArrayMesh.ARRAY_COLOR] = colors
	var mesh = ArrayMesh.new()
	# Flags 0 for ARRAY_COMPRESS_VERTEX's sake: the default stores 2D positions as
	# half floats, whose spacing is 8 units above 8192, so band pieces meant to
	# butt against each other on the far side of a large map snapped to an 8-px
	# lattice and could part company at a joint. No colour interpolant here (the
	# band is flat black), but the geometry has to close.
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], 0)
	return {"mesh": mesh, "area": area}

func _band_tri(tris: Array, a: Vector2, b: Vector2, c: Vector2):
	tris.append(a)
	tris.append(b)
	tris.append(c)

# Fan of triangles sweeping from normal n0 to n1 around `pivot`, radius
# padded so the fan's straight CHORDS never dip inside `dist` (the chord of a
# 0.6 rad step sags ~4.5%, which would eat the band's safety margin under a
# tall wall).
func _band_fan(tris: Array, pivot: Vector2, n0: Vector2, n1: Vector2, dist: float):
	var ang = n0.angle_to(n1)
	# Skip only float-noise joints. A 0.01 rad cutoff left a REAL uncovered
	# wedge between the two swept rectangles (they only meet exactly at ang=0):
	# at a 4000 px band reach a 0.0099 rad joint leaked a ~40 px-wide sliver of
	# un-suppressed shadow at the rim — visible streaks on gently curved walls.
	# At 1e-4 the worst leak is sub-pixel.
	if abs(ang) < 0.0001:
		return
	var steps = int(max(1, ceil(abs(ang) / 0.6)))
	var r = dist / cos(abs(ang) / float(steps) * 0.5)
	for k in range(steps):
		var a0 = n0.rotated(ang * float(k) / float(steps)).normalized()
		var a1 = n0.rotated(ang * float(k + 1) / float(steps)).normalized()
		_band_tri(tris, pivot, pivot + a0 * r, pivot + a1 * r)

# Subtract CW hole polygons from CCW solids, producing simple (triangulable)
# pieces: each hole splits every piece vertically through the hole's centre,
# then the hole is clipped out of each half. Shared by the wall-ring strip and
# _rect_minus contour fills.
func _subtract_holes(solids: Array, holes: Array) -> Array:
	for hole in holes:
		var bbox = _poly_bbox(hole)
		var cx = bbox.position.x + bbox.size.x * 0.5
		var next_pieces = []
		for piece in solids:
			for half_piece in _split_at_x(piece, cx):
				for cut in Geometry.clip_polygons_2d(_to_packed(half_piece), _to_packed(hole)):
					if cut.size() >= 3 and not Geometry.is_polygon_clockwise(cut):
						next_pieces.append(cut)
		solids = next_pieces
	return solids

# The polygon's parts left and right of the vertical line at cx.
func _split_at_x(poly, cx: float) -> Array:
	var b = _poly_bbox(poly).grow(64.0)
	var left = PoolVector2Array([
		Vector2(b.position.x, b.position.y), Vector2(cx, b.position.y),
		Vector2(cx, b.end.y), Vector2(b.position.x, b.end.y)])
	var right = PoolVector2Array([
		Vector2(cx, b.position.y), Vector2(b.end.x, b.position.y),
		Vector2(b.end.x, b.end.y), Vector2(cx, b.end.y)])
	var out = []
	for r in [left, right]:
		for p in Geometry.intersect_polygons_2d(_to_packed(poly), r):
			if p.size() >= 3 and not Geometry.is_polygon_clockwise(p):
				out.append(p)
	return out

func _count_inside(poly, samples: Array) -> int:
	var packed = _to_packed(poly)
	if packed.size() < 3:
		return 0
	var hits = 0
	for p in samples:
		if Geometry.is_point_in_polygon(p, packed):
			hits += 1
	return hits

# Snap an endpoint PERPENDICULARLY out to its nearest map edge.
#
# An earlier version extended along the contour's terminal tangent, which can
# aim back across the contour and manufacture self-intersections that were not
# in the original line — and a self-intersecting polygon cannot be triangulated.
# Since DD won't let you draw past the canvas, an endpoint that belongs at the
# edge is already sitting on it, so a short perpendicular hop is all that is
# needed and it cannot cross anything.
func _snap_to_boundary(from: Vector2) -> Vector2:
	if _raster_rect == null:
		return from
	var d_left = from.x - _raster_rect.position.x
	var d_right = _raster_rect.end.x - from.x
	var d_top = from.y - _raster_rect.position.y
	var d_bottom = _raster_rect.end.y - from.y
	var best = d_left
	var out = Vector2(_raster_rect.position.x - 8.0, from.y)
	if d_right < best:
		best = d_right
		out = Vector2(_raster_rect.end.x + 8.0, from.y)
	if d_top < best:
		best = d_top
		out = Vector2(from.x, _raster_rect.position.y - 8.0)
	if d_bottom < best:
		best = d_bottom
		out = Vector2(from.x, _raster_rect.end.y + 8.0)
	return out

# How close to an edge an endpoint must be to count as "the canvas cut this off".
func _endpoint_at_edge(p: Vector2, threshold: float) -> bool:
	if _map_rect == null:
		return false
	return min(min(p.x - _map_rect.position.x, _map_rect.end.x - p.x),
		min(p.y - _map_rect.position.y, _map_rect.end.y - p.y)) <= threshold

# Which side of the rect a boundary point lies on: 0=top 1=right 2=bottom 3=left.
func _edge_index(p: Vector2) -> int:
	var d_top = abs(p.y - _raster_rect.position.y)
	var d_bottom = abs(p.y - _raster_rect.end.y)
	var d_left = abs(p.x - _raster_rect.position.x)
	var d_right = abs(p.x - _raster_rect.end.x)
	var best = d_top
	var idx = 0
	if d_right < best:
		best = d_right
		idx = 1
	if d_bottom < best:
		best = d_bottom
		idx = 2
	if d_left < best:
		best = d_left
		idx = 3
	return idx

func _rect_corner(i: int) -> Vector2:
	# Corners in clockwise order starting top-left.
	if i % 4 == 0:
		return Vector2(_raster_rect.position.x, _raster_rect.position.y)
	if i % 4 == 1:
		return Vector2(_raster_rect.end.x, _raster_rect.position.y)
	if i % 4 == 2:
		return Vector2(_raster_rect.end.x, _raster_rect.end.y)
	return Vector2(_raster_rect.position.x, _raster_rect.end.y)

# Walk the rect boundary from `from_edge` to `to_edge`, collecting the corners
# passed. `clockwise` picks which way round — we try both and keep whichever
# encloses the uphill test point, which avoids all winding-sign reasoning.
func _boundary_corners(from_edge: int, to_edge: int, clockwise: bool) -> Array:
	var corners = []
	var e = from_edge
	var guard = 0
	while e != to_edge and guard < 5:
		if clockwise:
			corners.append(_rect_corner(e + 1))
			e = (e + 1) % 4
		else:
			corners.append(_rect_corner(e))
			e = (e + 3) % 4
		guard += 1
	return corners

# Turn one contour into one or more filled polygons covering its uphill side.
func _contour_to_polygons(path, side: int) -> Array:
	var pts = _world_points(path)
	if pts.size() < 2:
		return []


	var samples = _uphill_sample_points(pts, side)
	if samples.size() == 0:
		outputlog("path %s: no usable uphill samples, skipping" % str(core.get_node_id(path)), 0)
		return []

	if _is_closed(path):
		var closed_poly = []
		for p in pts:
			closed_poly.append(p)
		return _pick_by_vote(path, closed_poly, _rect_minus(closed_poly), samples, "closed")

	# Open contour: decide from the ORIGINAL endpoints whether the canvas cut
	# this contour off, then hop perpendicular to the edge if so.
	var edge_tol = float(sun_settings.get_sun().get("tier_px", 256.0)) * 1.5
	var last = pts.size() - 1
	var start_on_edge = _endpoint_at_edge(pts[0], edge_tol)
	var end_on_edge = _endpoint_at_edge(pts[last], edge_tol)
	var start_ext = _snap_to_boundary(pts[0]) if start_on_edge else pts[0]
	var end_ext = _snap_to_boundary(pts[last]) if end_on_edge else pts[last]

	var spine = [start_ext]
	for p in pts:
		spine.append(p)
	spine.append(end_ext)

	if start_on_edge and end_on_edge:
		# Close around the map rectangle, walking the corners each way.
		var e_from = _edge_index(end_ext)
		var e_to = _edge_index(start_ext)
		var poly_cw = spine.duplicate()
		for c in _boundary_corners(e_from, e_to, true):
			poly_cw.append(c)
		var poly_ccw = spine.duplicate()
		for c in _boundary_corners(e_from, e_to, false):
			poly_ccw.append(c)
		# Both endpoints leaving through the SAME edge yields no corners either
		# way, so the two candidates are identical. The real alternative is then
		# the complement.
		if poly_cw.size() == poly_ccw.size() and e_from == e_to:
			return _pick_by_vote(path, poly_cw, _rect_minus(poly_cw), samples, "same-edge")
		return _pick_by_vote(path, poly_cw, poly_ccw, samples, "boundary")

	# Endpoints inside the map: close with a direct chord.
	var chord = spine.duplicate()
	return _pick_by_vote(path, chord, _rect_minus(chord), samples, "chord")

# Choose whichever candidate region actually holds the uphill samples.
#
# Never silently defaults to the complement: filling ~99% of the map is the most
# damaging possible wrong answer, since it adds a phantom tier of elevation
# everywhere. On a tie or a total miss, prefer the SMALLER region — a contour
# bounds a modest area far more often than it bounds the entire map.
func _pick_by_vote(path, cand_a, cand_b, samples: Array, why: String) -> Array:
	var a_list = cand_a if (cand_a is Array and cand_a.size() > 0 and cand_a[0] is PoolVector2Array) else [cand_a]
	var b_list = cand_b if (cand_b is Array and cand_b.size() > 0 and cand_b[0] is PoolVector2Array) else [cand_b]

	var a_votes = 0
	for poly in a_list:
		a_votes += _count_inside(poly, samples)
	var b_votes = 0
	for poly in b_list:
		b_votes += _count_inside(poly, samples)

	var a_area = 0.0
	for poly in a_list:
		a_area += abs(_poly_area(poly))
	var b_area = 0.0
	for poly in b_list:
		b_area += abs(_poly_area(poly))

	var nid = str(core.get_node_id(path))
	if a_votes == 0 and b_votes == 0:
		var pick_small = a_list if a_area <= b_area else b_list
		outputlog("path %s (%s): no samples inside either candidate, taking smaller region (%.1f%% vs %.1f%% of map)" % [
			nid, why, 100.0 * min(a_area, b_area) / _map_area(), 100.0 * max(a_area, b_area) / _map_area()], 0)
		return pick_small

	if a_votes == b_votes:
		outputlog("path %s (%s): tie at %d/%d votes, taking smaller region" % [
			nid, why, a_votes, samples.size()], 0)
		return a_list if a_area <= b_area else b_list

	outputlog("path %s (%s): votes %d vs %d of %d samples" % [
		nid, why, a_votes, b_votes, samples.size()], 1)
	return a_list if a_votes > b_votes else b_list

func _map_area() -> float:
	if _map_rect == null:
		return 1.0
	return max(1.0, _map_rect.size.x * _map_rect.size.y)

# Map rectangle with `hole` removed — used when uphill is outside a closed loop.
#
# clip_polygons_2d expresses the result as the outer boundary PLUS the hole's
# outline (clockwise). Returning both raw used to be catastrophic, in two ways
# found independently by both cold-read agents (2026-08-07):
#   * rebuild() cleaned each polygon in ISOLATION — merge_polygons_2d(hole,
#     hole) normalised the CW hole into a solid — and the additive blend then
#     stacked a SECOND helping of height inside the loop: the whole map gained
#     a phantom tier per closed contour and loop interiors sat at 2h instead
#     of 0 (tier histogram baseline 4 instead of 1; measured stack 14.05 tiers
#     vs the analytic bound 11.8, which is impossible without double-fill).
#   * _pick_by_vote counted a sample inside the loop as inside the rect-minus
#     candidate TOO (via the hole member) — the log showed "votes 2 vs 5 of 3
#     samples" — inverting the side vote toward rect-minus.
# Resolving the hole HERE, into disjoint simple solids, fixes the fill, the
# vote and the area comparison in one place.
func _rect_minus(hole: Array) -> Array:
	if _raster_rect == null:
		return []
	var rect_poly = [
		Vector2(_raster_rect.position.x, _raster_rect.position.y),
		Vector2(_raster_rect.end.x, _raster_rect.position.y),
		Vector2(_raster_rect.end.x, _raster_rect.end.y),
		Vector2(_raster_rect.position.x, _raster_rect.end.y),
	]
	var result = Geometry.clip_polygons_2d(_to_packed(rect_poly), _to_packed(hole))
	var solids = []
	var cw_holes = []
	for poly in result:
		if poly.size() < 3:
			continue
		if Geometry.is_polygon_clockwise(poly):
			cw_holes.append(poly)
		else:
			solids.append(poly)
	return _subtract_holes(solids, cw_holes)

#########################################################################################################
## RASTERISE
#########################################################################################################

# Resolve a self-intersecting outline into simple, triangulable polygons.
#
# Required, not optional: a branching contour crosses itself, and
# triangulate_polygon returns nothing for any self-intersecting input — which is
# exactly why the first build produced 0 polygons. Unioning a polygon with
# itself makes Clipper rewrite the crossings into clean boundaries.
#
# Clipper returns outer boundaries counter-clockwise and holes clockwise, so
# holes are dropped: filling them would add height where there is none.
func _clean_polygon(poly) -> Array:
	var packed = _to_packed(poly)
	if packed.size() < 3:
		return []
	var merged = Geometry.merge_polygons_2d(packed, packed)
	if merged.size() == 0:
		# Nothing to clean up (or Clipper declined) — try the raw outline.
		return [packed]
	var solids = []
	var holes = 0
	for p in merged:
		if p.size() < 3:
			continue
		if Geometry.is_polygon_clockwise(p):
			holes += 1
			continue
		solids.append(p)
	if solids.size() == 0:
		# Orientation convention did not match expectations; keep everything
		# rather than silently dropping the whole tier.
		outputlog("clean: all %d parts read as holes, keeping them anyway" % merged.size(), 0)
		for p in merged:
			if p.size() >= 3:
				solids.append(p)
	if merged.size() > 1:
		outputlog("clean: %d-point outline -> %d solid(s), %d hole(s)" % [
			packed.size(), solids.size(), holes], 1)
	return solids

func _poly_bbox(poly) -> Rect2:
	var packed = _to_packed(poly)
	if packed.size() == 0:
		return Rect2()
	var r = Rect2(packed[0], Vector2.ZERO)
	for p in packed:
		r = r.expand(p)
	return r

# Shoelace area. Sign indicates winding; callers take abs().
func _poly_area(poly) -> float:
	var packed = _to_packed(poly)
	var n = packed.size()
	if n < 3:
		return 0.0
	var total = 0.0
	for i in range(n):
		var a = packed[i]
		var b = packed[(i + 1) % n]
		total += a.x * b.y - b.x * a.y
	return total * 0.5

# The height goes into ONE colour channel — the one belonging to this caster's
# layer group — not into all three. That channel is the whole per-layer
# attribution mechanism; see the SLOTS notes at the top of this file.
func _channel_color(channel: int, value: float) -> Color:
	if channel == 0:
		return Color(value, 0.0, 0.0, 1.0)
	if channel == 1:
		return Color(0.0, value, 0.0, 1.0)
	return Color(0.0, 0.0, value, 1.0)

func _make_polygon_mesh(poly, c: Color):
	var packed = _to_packed(poly)
	if packed.size() < 3:
		return null
	var tri = Geometry.triangulate_polygon(packed)
	if tri.size() < 3:
		outputlog("triangulation failed for a %d-point polygon even after cleaning" % packed.size(), 0)
		return null

	var verts = PoolVector2Array()
	var colors = PoolColorArray()
	for idx in tri:
		verts.append(packed[idx])
		colors.append(c)

	var arrays = []
	arrays.resize(ArrayMesh.ARRAY_MAX)
	arrays[ArrayMesh.ARRAY_VERTEX] = verts
	arrays[ArrayMesh.ARRAY_COLOR] = colors
	var mesh = ArrayMesh.new()
	# COMPRESS FLAGS 0 — LOAD-BEARING, this is not a micro-optimisation.
	#
	# The default (ARRAY_COMPRESS_DEFAULT) sets ARRAY_COMPRESS_COLOR, which stores
	# each vertex colour as `int(c * 255.0)` — a TRUNCATION, not a rounding. This
	# colour is not decoration: it IS the height, as tiers/HEIGHT_DIVISOR. So
	#     h=4 -> 0.0625  -> int(15.94) = 15 -> 15/255 -> 3.754 tiers
	#     h=2 -> 0.03125 -> int( 7.97) =  7 ->  7/255 -> 1.752 tiers
	#     h=1 ->           int( 3.98) =  3 ->  3/255 -> 0.751 tiers
	# every fill rasterised about a QUARTER TIER SHORT, always short, never long.
	#
	# On its own that was a quiet 6% error in shadow length. It became a visible
	# defect when the ART FOOTPRINT arrived: the footprint's height comes from a
	# shader uniform (`elevation`), which is exact, so `max(fill, art)` in
	# HeightSmooth picked the ART everywhere the two overlapped and every art band
	# stood ~0.25 tiers PROUD of the plateau it lies on — a ridge with a drop on
	# its INNER side, casting a short soft shadow back across the caster's own high
	# ground. That is Arthur's "it behaves as if I have it on Side A, casting
	# shadow inside of itself, in random spots": the lip is 0.25 tiers against a
	# `self_bias` of 0.22-0.26, so it clears the march's noise gate only where the
	# local blur and sampling nudge it over — random spots, and stronger at low
	# Diffusion (self_bias = 0.10 + level_blend * 0.04). The mod's own probe row
	# printed it in the log and it was read as a success: `field: 3.8 x11 4.0 x18
	# 3.8 x11` under a mask that starts and ends inside the plateau.
	#
	# ARRAY_COMPRESS_VERTEX is in the same default and matters here too: it stores
	# 2D positions as HALF FLOATS, whose spacing is 8 units above 8192, so contour
	# vertices on the far side of a large map snapped to an 8-world-px lattice and
	# the fill boundary drifted off the art centreline by up to 4 px.
	#
	# ShadowRenderer._add_quad already passes 0 for the same class of reason.
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], 0)
	return mesh

#########################################################################################################
## LAYER GROUPS
#########################################################################################################
# Enabled casters are partitioned by their DD layer (z_index). One group == one
# slot == one colour channel == one shadow node at z = layer.
#
# NOTE: the mod NEVER writes z_index to a caster, an object or a container. It
# only reads z_index here, and only ever sets z on the sprites it creates itself.

func _build_groups():
	_groups = []
	var casters = path_tagging.get_caster_nodes()
	if casters.size() == 0:
		return

	var by_layer = {}
	for path in casters:
		var key = int(round(path_tagging.get_caster_layer(path)))
		if not by_layer.has(key):
			by_layer[key] = []
		by_layer[key].append(path)

	var keys = by_layer.keys()
	keys.sort()

	# Only six channels exist (two chains x RGB). More distinct layers than that
	# is a degenerate case: fold the LOWEST ones together rather than dropping
	# their shadows entirely, and say so loudly — the merged layers share one
	# sprite, so the lower of them will have its art darkened by the higher.
	while keys.size() > MAX_SLOTS:
		var lowest = keys[0]
		var second = keys[1]
		outputlog("WARNING: %d distinct caster layers but only %d slots — merging layer %d into layer %d" % [
			keys.size(), MAX_SLOTS, lowest, second], 0)
		for path in by_layer[lowest]:
			by_layer[second].append(path)
		by_layer.erase(lowest)
		keys.remove(0)

	for i in range(keys.size()):
		_groups.append({
			"layer": float(keys[i]),
			"slot": i,
			"casters": by_layer[keys[i]],
		})
		if keys[i] < 0:
			outputlog(("WARNING: slot %d is layer %d — its shadow node lands below DD's " +
				"default containers (z 0) and will darken almost nothing. Assign these " +
				"paths a Layer (1..4) in DD's Layer dropdown.") % [i, keys[i]], 0)

	var summary = PoolStringArray()
	for g in _groups:
		summary.append("slot %d = layer %d (%d caster%s)" % [
			g["slot"], int(g["layer"]), g["casters"].size(),
			"" if g["casters"].size() == 1 else "s"])
	outputlog("layer groups: %d — %s" % [_groups.size(), summary.join(", ")], 0)

func get_group_count() -> int:
	return _groups.size()

func get_group_layer(index: int) -> float:
	if index < 0 or index >= _groups.size():
		return 0.0
	return float(_groups[index]["layer"])

func get_group_caster_count(index: int) -> int:
	if index < 0 or index >= _groups.size():
		return 0
	return _groups[index]["casters"].size()

func get_group_casters(index: int) -> Array:
	if index < 0 or index >= _groups.size():
		return []
	return _groups[index]["casters"]

func get_chain_count() -> int:
	return _chains.size()

func get_viewport_count() -> int:
	return _viewport_count


#########################################################################################################
## RASTERISE
#########################################################################################################

# One raster chain: the additive polygon target plus its two blur passes. Three
# render targets per chain, and a chain carries up to SLOTS_PER_CHAIN layers.
func _make_raster_chain(vp_size: Vector2) -> Dictionary:
	var vp = Viewport.new()
	vp.size = vp_size
	vp.usage = Viewport.USAGE_2D
	vp.transparent_bg = true
	vp.disable_3d = true
	# MUST be true. Godot 3 render targets are stored bottom-up, so a
	# ViewportTexture drawn on a Sprite appears vertically mirrored without this.
	# With it false, content near the map's bottom edge rendered near the top —
	# which reads as "wrong position and rotation" even though nothing in the
	# transform chain rotates anything.
	vp.render_target_v_flip = true
	vp.render_target_update_mode = Viewport.UPDATE_ONCE

	# World -> viewport: scale down, then shift the map's origin to (0,0).
	var root = Node2D.new()
	root.scale = Vector2(_vp_scale, _vp_scale)
	root.position = -_raster_rect.position * _vp_scale
	vp.add_child(root)

	# Park the viewport somewhere harmless in the tree. A Viewport is not a
	# CanvasItem, so it does not draw into the map itself.
	global.Editor.add_child(vp)

	return {
		"raster": vp,
		"root": root,
		# ART FOOTPRINT target — created lazily by _ensure_art_target, and NOT
		# part of the additive fill raster on purpose: the blur pass combines the
		# two with max() so a path's art can overlap its own fill for free.
		"art": null,
		"art_root": null,
		"blur_h": null,
		"blur_v": null,
		"spr_h": null,
		"spr_v": null,
	}

func rebuild():
	_map_rect = _resolve_map_rect()
	if _map_rect == null:
		outputlog("no map rect — height field not built", 0)
		return

	_raster_rect = _compute_raster_rect()

	_teardown_viewport()

	_build_groups()
	if _groups.size() == 0:
		# Nothing is built and, critically, no sprite is created. The old code
		# derived one sprite's z from get_max_caster_layer(), which returned 0.0 for
		# an empty caster set and parked the sprite at z=1 under everything.
		outputlog("no enabled casters — 0 layer groups, 0 render targets, nothing built", 0)
		return

	var map_size = _raster_rect.size
	var longest = max(map_size.x, map_size.y)
	_vp_scale = min(1.0, _cap_dim() / longest)
	var vp_size = Vector2(
		max(4.0, floor(map_size.x * _vp_scale)),
		max(4.0, floor(map_size.y * _vp_scale)))

	var chain_count = int(ceil(float(_groups.size()) / float(SLOTS_PER_CHAIN)))
	for _i in range(chain_count):
		_chains.append(_make_raster_chain(vp_size))

	var drawn = 0
	var skipped = 0
	var art_raised = 0
	var art_candidates = 0
	_slot_art_max = []
	for _i in range(_groups.size()):
		_slot_art_max.append(0.0)
	# (raster rect was already computed from these casters above)

	for gi in range(_groups.size()):
		var group = _groups[gi]
		var chain = _chains[int(gi / SLOTS_PER_CHAIN)]
		var channel = gi % SLOTS_PER_CHAIN
		var group_drawn = 0

		for path in group["casters"]:
			var cfg = path_tagging.get_config(path)
			var height = float(cfg.get("height", 1.0))
			var side = int(cfg.get("side", 0))
			var is_wall = path_tagging.is_wall_node(path)

			# PATHS — Side A/B: a terrain step, one side uphill, filled to the
			# map edge (or the closure); "Wall (both)": a FREE-STANDING WALL
			# strip, both sides low. WALL NODES are ALWAYS a strip (a wall on
			# side 0/1 used to fall into the contour fill and silently cover
			# half the map); for them side 0/1 means CAST ON ONE SIDE ONLY —
			# the strip still rasterises identically (elevation is a scalar
			# and cannot be one-sided) and the un-cast side is erased from the
			# bake via the group's beam mask (_register_side_suppressor).
			var polys
			var ring = {}
			if is_wall or side == 2:
				# cut_portals=false: the elevation stays SOLID across open
				# portals — beams are carved out of the bake by the beam
				# masks, not out of the field (the blocker still gaps, so
				# other casters' shadows pass through open doors).
				polys = _path_strip_polygons(path, float(cfg.get("mask_inset", 5.0)), false, ring)
			else:
				polys = _contour_to_polygons(path, side)
			if polys.size() == 0:
				skipped += 1
				continue
			if is_wall and side != 2:
				_register_side_suppressor(gi, path, side, ring, height)

			# The elevation step sits ON the drawn centreline — deliberately not
			# pulled back from it (the removed `edge_inset_mult` approach): the
			# per-layer art mask hides the shadow's leading edge under the art, so
			# offsetting the step would only produce the smooth-curve boundary the
			# user rejected.
			var parts = []
			for poly in polys:
				for cleaned in _clean_polygon(poly):
					parts.append(cleaned)

			for poly in parts:
				# Report what each fill actually covers. "covers X% of map" is the
				# fast tell for a wrong-side fill: a contour region should be a
				# modest fraction, not ~100%.
				var bbox = _poly_bbox(poly)
				var map_area = max(1.0, _map_rect.size.x * _map_rect.size.y)
				outputlog("  slot %d path %s h=%.2f poly %d pts bbox=%s area=%.1f%% of map" % [
					gi, str(core.get_node_id(path)), height, poly.size(), str(bbox),
					100.0 * abs(_poly_area(poly)) / map_area], 0)

				var mesh = _make_polygon_mesh(poly, _channel_color(channel, height / HEIGHT_DIVISOR))
				if mesh == null:
					continue
				var mi = MeshInstance2D.new()
				mi.mesh = mesh
				# Additive so nested contours accumulate into stacked tiers. Because
				# each group writes only its own channel, contours on DIFFERENT layers
				# still stack into the total (= the sum of the channels) while staying
				# individually attributable.
				var mat = CanvasItemMaterial.new()
				mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
				mi.material = mat
				chain["root"].add_child(mi)
				drawn += 1
				group_drawn += 1

			# ART FOOTPRINT — only now, after the fill actually rasterised. A
			# contour whose closure failed (`polys.size() == 0` above) must not
			# get one either: art elevation with no fill under it is a floating
			# ridge, and its far edge would cast a shadow back across the hill.
			if _has_art_footprint(path):
				art_candidates += 1
				if _draw_art_footprint(chain, gi, channel, path, height, vp_size) > 0:
					art_raised += 1

		outputlog("slot %d: layer %d -> chain %d channel %s, %d caster(s), %d polygon(s)" % [
			gi, int(group["layer"]), int(gi / SLOTS_PER_CHAIN), ["R", "G", "B"][channel],
			group["casters"].size(), group_drawn], 0)

	# THE RELOAD CANARY for this feature. `[artfoot v4]` = exact-height fills
	# (compress flags 0), so the max-combine is a no-op where a path's art lies on
	# its own fill; `v3` is the build whose art bands stood a quarter tier proud of
	# their own plateau; `v1`/`v2.1` are the older rejected branches.
	var clamp_parts = PoolStringArray()
	for gi in range(_slot_art_max.size()):
		clamp_parts.append("%.2f" % _slot_art_max[gi])
	outputlog("art footprint [artfoot v4] %s: %d of %d contour path(s) raised onto their own art (alpha >= %.2f) | per-slot clamp tiers: %s" % [
		"ON" if bool(sun_settings.get_sun().get("bake_art_elevation", true)) else "OFF (Art raises elevation unticked)",
		art_raised, art_candidates, ART_ALPHA_THRESHOLD, clamp_parts.join(" / ")], 0)

	_build_smooth_passes(vp_size)
	_build_art_masks(vp_size)
	_build_blockers(vp_size)

	_viewport_count = 0
	for chain in _chains:
		for key in ["raster", "art", "blur_h", "blur_v"]:
			if chain[key] != null and is_instance_valid(chain[key]):
				_viewport_count += 1
	for mc in _mask_chains:
		if mc != null and mc["vp"] != null and is_instance_valid(mc["vp"]):
			_viewport_count += 1

	outputlog("built: %d polygon(s) from %d group(s), %d skipped | vp=%s scale=%.4f | %d render target(s) in %d chain(s)" % [
		drawn, _groups.size(), skipped, str(vp_size), _vp_scale, _viewport_count, _chains.size()], 0)

	_refresh_debug_sprite()

	# The render target needs a frame before its pixels exist, so sample the
	# finished field on a short delay. A numeric tier histogram verifies nesting
	# accumulation directly, instead of relying on telling grey shades apart by
	# eye — hopeless once the debug amplification saturates.
	var timer = Timer.new()
	timer.wait_time = 0.3
	timer.one_shot = true
	timer.connect("timeout", self, "_log_histogram")
	global.Editor.add_child(timer)
	timer.start()

# Read the raster back and report:
#   * the TOTAL tier histogram (sum of every channel), same meaning as before;
#   * per-slot coverage, which is the fast tell that a layer group actually
#     rasterised something into its own channel;
#   * the measured maximum stack, which bounds the march.
func _log_histogram():
	if _chains.size() == 0:
		return

	# Fill raster AND art footprint, kept index-aligned: every probe below has to
	# combine them exactly the way HeightSmooth's first pass does
	# (max(fill, min(art, clamp))), or it reports a field the march never sees.
	# The raw raster alone would show none of the art footprint at all — the
	# HANDOFF's standing rule, learned from the melted wall strip: probes must
	# read what the consumer reads.
	var imgs = []
	var art_imgs = []
	for chain in _chains:
		var vp = chain["raster"]
		if vp == null or not is_instance_valid(vp):
			continue
		var tex = vp.get_texture()
		if tex == null:
			continue
		var img = tex.get_data()
		if img == null:
			continue
		img.lock()
		imgs.append(img)
		var aimg = null
		if chain["art"] != null and is_instance_valid(chain["art"]):
			var atex = chain["art"].get_texture()
			if atex != null:
				aimg = atex.get_data()
				if aimg != null:
					aimg.lock()
		art_imgs.append(aimg)

	if imgs.size() == 0:
		outputlog("histogram: render target not readable yet", 0)
		return

	var w = imgs[0].get_width()
	var h = imgs[0].get_height()
	var counts = {}
	var slot_hits = []
	var proud_hits = []
	var proud_samples = []
	var proud_max = []
	for _i in range(_groups.size()):
		slot_hits.append(0)
		proud_hits.append(0)
		proud_samples.append(0)
		proud_max.append(0.0)
	var samples = 0
	var observed = 0.0
	var step = max(1, int(min(w, h) / 96))
	var y = 0
	while y < h:
		var x = 0
		while x < w:
			var total = 0.0
			for ci in range(imgs.size()):
				var col = imgs[ci].get_pixel(x, y)
				var acol = null
				if art_imgs[ci] != null:
					acol = art_imgs[ci].get_pixel(x, y)
				for k in range(SLOTS_PER_CHAIN):
					var slot = ci * SLOTS_PER_CHAIN + k
					var v = _chan(col, k)
					if acol != null and slot < _slot_art_max.size():
						var a = min(_chan(acol, k), _slot_art_max[slot] / HEIGHT_DIVISOR)
						# ART-OVER-FILL RIDGES — the number this round exists for.
						# Count every texel where the footprint stands STRICTLY
						# ABOVE the fill underneath it. `max()` picks the art there,
						# so each one is a lip inside the caster's own plateau with
						# a drop on its inner side — the thing that casts shadow
						# into high ground. The 8-bit vertex-colour truncation put
						# +0.25 tiers of it under essentially EVERY art band; with
						# exact fills that must fall to ~0, and anything LEFT is
						# real geometry (two same-slot paths of different heights
						# whose art overlaps and ADDS, bounded by the per-slot
						# clamp) which shows up as a whole-tier `max +`, not 0.25.
						if v > FILL_EPS and a > FILL_EPS and slot < proud_hits.size():
							proud_samples[slot] += 1
							var excess = (a - v) * HEIGHT_DIVISOR
							if excess > 0.05:
								proud_hits[slot] += 1
								if excess > proud_max[slot]:
									proud_max[slot] = excess
						v = max(v, a)
					total += v
					if slot < slot_hits.size() and v * HEIGHT_DIVISOR > 0.05:
						slot_hits[slot] += 1
			var tiers = total * HEIGHT_DIVISOR
			if tiers > observed:
				observed = tiers
			var tier = int(round(tiers))
			counts[tier] = counts.get(tier, 0) + 1
			samples += 1
			x += step
		y += step
	for img in imgs:
		img.unlock()
	for img in art_imgs:
		if img != null:
			img.unlock()

	var keys = counts.keys()
	keys.sort()
	var parts = PoolStringArray()
	for k in keys:
		parts.append("%d:%.1f%%" % [k, 100.0 * counts[k] / max(1, samples)])
	outputlog("tier histogram (%d samples): %s" % [samples, parts.join(", ")], 0)

	var cov = PoolStringArray()
	for gi in range(_groups.size()):
		cov.append("slot %d/layer %d: %.1f%%" % [
			gi, int(_groups[gi]["layer"]), 100.0 * slot_hits[gi] / max(1, samples)])
	outputlog("per-layer field coverage: %s" % cov.join(" | "), 0)

	# THE ACCEPT TEST for this round. Denominator = grid samples where BOTH the
	# fill and the footprint are present; numerator = those where the footprint
	# stands above the fill by more than 0.05 tiers, i.e. a ridge inside the
	# caster's own plateau. Under the 8-bit truncation this was ~100% at +0.25;
	# with exact fills it must be ~0%.
	var proud = PoolStringArray()
	var proud_total = 0
	var proud_denom = 0
	for gi in range(_groups.size()):
		proud_total += proud_hits[gi]
		proud_denom += proud_samples[gi]
		proud.append("slot %d: %d/%d max +%.2f t" % [
			gi, proud_hits[gi], proud_samples[gi], proud_max[gi]])
	outputlog("art-over-fill ridges: %d of %d overlap sample(s) where the footprint stands ABOVE its own fill (%.1f%% — want ~0) | %s" % [
		proud_total, proud_denom, 100.0 * proud_total / max(1, proud_denom), proud.join(" | ")], 0)

	_observed_max_tiers = observed
	# INFORMATIVE ONLY. This number used to cap the march's stack bound and
	# trigger re-bakes — deleted 2026-08-07: the sparse grid misses thin wall
	# strips, so the cap truncated their shadows, and because the value was
	# cached across rebuilds the truncation came and went with rebuild order
	# (the user watched a wall's shadow jump between 2-3 squares and full
	# length just by toggling an unrelated portal setting). The march now uses
	# the analytic bound only.
	outputlog("max stacked elevation measured: %.2f tiers (sparse grid, informative only)" % observed, 0)

	_log_mask_probe(imgs, art_imgs)

# MASK/FIELD ALIGNMENT PROBE. Diagnoses "the shadow starts N px away from the
# art" without eyeballing: for the first slot with mask coverage, find the row
# with the widest masked run and print, across a window around it, the FIELD
# channel (where the elevation step is — the shadow's origin) and the MASK
# channel (where the art is) side by side, plus the measured world-px offsets
# between the field step and the mask's edges. If the mask values are a solid
# 0/1 band with hard edges, the art's texture alpha did not reach the mask (a
# solid Line2D strip); if they ramp with texture detail, the mask is honest and
# any gap is geometry (step vs art placement), not masking.
func _log_mask_probe(raster_imgs: Array, art_imgs: Array = []):
	if _mask_chains.size() == 0 or _groups.size() == 0:
		return
	var mask_imgs = {}
	for ci in range(_mask_chains.size()):
		var tex = get_mask_texture(ci)
		if tex == null:
			continue
		var img = tex.get_data()
		if img == null:
			continue
		img.lock()
		mask_imgs[ci] = img

	if mask_imgs.size() == 0:
		outputlog("mask probe: no mask images readable", 0)
		return

	for img in raster_imgs:
		img.lock()
	for img in art_imgs:
		if img != null:
			img.lock()

	# Coverage and widest run per slot; remember the first slot worth profiling.
	# ALSO: the FIELD's peak height under each slot's mask. The tier histogram
	# samples a sparse grid that steps right over thin wall strips (slot
	# coverage 0.0% while the wall plainly casts), so this is the only readback
	# that can answer "did the strip rasterise at its full drop height" — the
	# decisive number for a too-short wall shadow.
	var profile = null
	for gi in range(_groups.size()):
		var ci = int(gi / SLOTS_PER_CHAIN)
		var ch = gi % SLOTS_PER_CHAIN
		if not mask_imgs.has(ci):
			continue
		var mimg = mask_imgs[ci]
		var w = mimg.get_width()
		var h = mimg.get_height()
		var fimg = raster_imgs[ci] if ci < raster_imgs.size() else null
		var aimg = art_imgs[ci] if ci < art_imgs.size() else null

		var hits = 0
		var samples = 0
		var best_y = -1
		var best_run = 0
		var best_start = -1
		var fpeak = 0.0
		var masked = 0
		var bare = 0
		var step = max(1, int(h / 96))
		var y = 0
		while y < h:
			var run = 0
			var start = -1
			for x in range(w):
				var v = _chan(mimg.get_pixel(x, y), ch)
				if v > 0.05:
					hits += 1
					if run == 0:
						start = x
					run += 1
					if run > best_run:
						best_run = run
						best_y = y
						best_start = start
					if fimg != null:
						var fv = _field_chan(fimg, aimg, x, y, ch, gi) * HEIGHT_DIVISOR
						if fv > fpeak:
							fpeak = fv
						# THE ACCEPT TEST for the art footprint, in one number:
						# every masked sample must now stand on raised ground.
						# On `main` eight of them sat over field 0.0 — the outer
						# half of the art over ground the field called low, which
						# is exactly what let a higher layer's shadow qualify
						# there and draw a line across the art.
						if fv <= 0.0:
							bare += 1
						masked += 1
				else:
					run = 0
				samples += 1
			y += step
		outputlog("mask probe slot %d/layer %d: coverage %.2f%% widest run %d texels (%.0f world px) at row %d | field peak under mask %.2f tiers | %d of %d masked samples on BARE ground (%.1f%% — want 0)" % [
			gi, int(_groups[gi]["layer"]), 100.0 * hits / max(1, samples),
			best_run, best_run / max(0.0001, _vp_scale), best_y, fpeak,
			bare, masked, 100.0 * bare / max(1, masked)], 0)
		if profile == null and best_run > 4:
			profile = {"gi": gi, "ci": ci, "ch": ch, "y": best_y,
				"run": best_run, "start": best_start, "w": w}

	if profile != null:
		var gi = profile["gi"]
		var ci = profile["ci"]
		var ch = profile["ch"]
		var best_y = profile["y"]
		var best_run = profile["run"]
		var best_start = profile["start"]
		var w = profile["w"]
		var mimg = mask_imgs[ci]
		var fimg = raster_imgs[ci] if ci < raster_imgs.size() else null
		var aimg = art_imgs[ci] if ci < art_imgs.size() else null
		if fimg != null:
			# Window: the run plus margin either side, 40 sample points.
			var margin = int(max(4, best_run / 2))
			var x0 = int(max(0, best_start - margin))
			var x1 = int(min(w - 1, best_start + best_run + margin))
			var n = 40
			var mvals = PoolStringArray()
			var fvals = PoolStringArray()
			for k in range(n):
				var xi = x0 + int(float(k) * float(x1 - x0) / float(n - 1))
				mvals.append("%.2f" % _chan(mimg.get_pixel(xi, best_y), ch))
				fvals.append("%.1f" % (_field_chan(fimg, aimg, xi, best_y, ch, gi) * HEIGHT_DIVISOR))
			# Where the field step sits inside the same window.
			var f_edge = -1
			for xi in range(x0, x1 + 1):
				if _field_chan(fimg, aimg, xi, best_y, ch, gi) * HEIGHT_DIVISOR > 0.25:
					f_edge = xi
					break
			outputlog("mask probe slot %d row %d window %d..%d (world x %.0f..%.0f):" % [
				gi, best_y, x0, x1, x0 / max(0.0001, _vp_scale) + _raster_rect.position.x,
				x1 / max(0.0001, _vp_scale) + _raster_rect.position.x], 0)
			outputlog("  mask : %s" % mvals.join(" "), 0)
			outputlog("  field: %s" % fvals.join(" "), 0)
			if f_edge >= 0:
				outputlog("  field step at texel %d; mask starts %d, ends %d -> step is %.0f px past mask start, %.0f px before mask end" % [
					f_edge, best_start, best_start + best_run - 1,
					(f_edge - best_start) / max(0.0001, _vp_scale),
					(best_start + best_run - 1 - f_edge) / max(0.0001, _vp_scale)], 0)
			else:
				outputlog("  field step NOT inside the window — mask and field disagree about where this contour is", 0)

	for img in raster_imgs:
		img.unlock()
	for img in art_imgs:
		if img != null:
			img.unlock()
	for ci in mask_imgs.keys():
		mask_imgs[ci].unlock()

# One channel of the field AS THE MARCH SEES IT: the fill raster combined with
# the art footprint the same way HeightSmooth's horizontal pass combines them.
# `aimg` null (no footprint on this chain) degrades to the plain fill.
#
# This row is where the bug was VISIBLE all along and got read as a success:
#   field: 3.8 x11  4.0 x18  3.8 x11
# under a mask that both starts and ends inside the plateau. 3.8 is the fill
# (h=4, truncated to 8 bits by ARRAY_COMPRESS_COLOR); 4.0 is the art footprint
# (exact). A quarter-tier ridge, with a drop on its inner side, along every art
# band on the map. When a probe row steps UP in the middle and back DOWN, that is
# a ridge, whatever the headline count says.
func _field_chan(fimg, aimg, x: int, y: int, ch: int, slot: int) -> float:
	var v = _chan(fimg.get_pixel(x, y), ch)
	if aimg == null or slot >= _slot_art_max.size():
		return v
	return max(v, min(_chan(aimg.get_pixel(x, y), ch), _slot_art_max[slot] / HEIGHT_DIVISOR))

func _chan(c: Color, ch: int) -> float:
	if ch == 0:
		return c.r
	if ch == 1:
		return c.g
	return c.b

# Renders each raw chain through HeightSmooth.shader at the same resolution.
func _build_smooth_passes(vp_size: Vector2):
	if _smooth_shader == null:
		outputlog("no smoothing shader — the march will read the RAW raster", 0)
		return

	var blend = float(sun_settings.get_sun().get("level_blend", 2.0))
	# Taps must cover the radius, or the tail of the Gaussian is truncated.
	var taps = int(clamp(ceil(blend * 2.0), 1.0, 24.0))
	var texel = Vector2(1.0 / vp_size.x, 1.0 / vp_size.y)

	for ci in range(_chains.size()):
		var chain = _chains[ci]
		# Pass 1: horizontal — and the ART FOOTPRINT COMBINE. The footprint is
		# max()ed into the field here, before any smoothing, so the art's raised
		# ground and the fill's are blurred together as one surface.
		var art_tex = null
		var art_clamp = Vector3(0.0, 0.0, 0.0)
		if chain["art"] != null and is_instance_valid(chain["art"]):
			art_tex = chain["art"].get_texture()
			for k in range(SLOTS_PER_CHAIN):
				var slot = ci * SLOTS_PER_CHAIN + k
				if slot < _slot_art_max.size():
					var v = _slot_art_max[slot] / HEIGHT_DIVISOR
					if k == 0:
						art_clamp.x = v
					elif k == 1:
						art_clamp.y = v
					else:
						art_clamp.z = v
		var pass_h = _make_blur_viewport(vp_size, chain["raster"].get_texture(),
			Vector2(1.0, 0.0), texel, taps, blend, art_tex, art_clamp)
		chain["blur_h"] = pass_h["vp"]
		chain["spr_h"] = pass_h["spr"]
		# Pass 2: vertical, reading pass 1 — already combined, so no art here.
		var pass_v = _make_blur_viewport(vp_size, pass_h["vp"].get_texture(),
			Vector2(0.0, 1.0), texel, taps, blend)
		chain["blur_v"] = pass_v["vp"]
		chain["spr_v"] = pass_v["spr"]

	outputlog("smoothing: %d separable blur chain(s) at %s, blend=%.2f texels, %d taps/side" % [
		_chains.size(), str(vp_size), blend, taps], 0)

func _make_blur_viewport(vp_size: Vector2, source_tex, dir: Vector2,
	texel: Vector2, taps: int, sigma: float,
	art_tex = null, art_clamp: Vector3 = Vector3(0.0, 0.0, 0.0)) -> Dictionary:

	var vp = Viewport.new()
	vp.size = vp_size
	vp.usage = Viewport.USAGE_2D
	vp.transparent_bg = true
	vp.disable_3d = true
	vp.render_target_v_flip = true
	vp.render_target_update_mode = Viewport.UPDATE_ALWAYS

	var mat = ShaderMaterial.new()
	mat.shader = _smooth_shader
	mat.set_shader_param("direction", dir)
	mat.set_shader_param("texel_size", texel)
	mat.set_shader_param("taps", taps)
	mat.set_shader_param("sigma", max(0.35, sigma))
	# `use_art` must be an explicit 0 when there is no footprint: an unbound
	# sampler2D reads as WHITE in Godot 3, and max(field, white) would return a
	# saturated field everywhere.
	mat.set_shader_param("use_art", 1.0 if art_tex != null else 0.0)
	mat.set_shader_param("art_clamp", art_clamp)
	if art_tex != null:
		art_tex.flags = Texture.FLAG_FILTER
		mat.set_shader_param("art_tex", art_tex)

	source_tex.flags = Texture.FLAG_FILTER

	var spr = Sprite.new()
	spr.texture = source_tex
	spr.centered = false
	spr.position = Vector2.ZERO
	spr.material = mat
	vp.add_child(spr)
	global.Editor.add_child(vp)
	# The caller keeps both references so neither is collected.
	return {"vp": vp, "spr": spr}

#########################################################################################################
## PER-LAYER ART MASK
#########################################################################################################
# Rasterise the artwork of every path flagged "Art above shadow" into ITS
# LAYER'S channel, chain/channel-packed exactly like the height field. Each
# layer's shadow pass attenuates by its own channel only, so the shadow slides
# under that layer's flagged art while HIGHER layers' shadows still darken it —
# the per-layer version of the old (deleted) global art mask, without the flaw
# that killed it: it no longer stops a 400 shadow covering 200 art.
#
# Copies each Line2D (points, width, texture) into an offscreen viewport using
# the same world->viewport transform as the field, so the mask lines up
# texel-for-texel. Same proven Line2D-copy trick the old art mask used.

func _build_art_masks(vp_size: Vector2):
	if _mask_shader == null:
		return
	var by_layer = path_tagging.get_art_above_paths()
	if by_layer.size() == 0:
		outputlog("art mask: no flagged paths — no mask targets built", 0)
		return

	var copied = 0
	var matched = 0
	for gi in range(_groups.size()):
		var layer_key = int(round(_groups[gi]["layer"]))
		if not by_layer.has(layer_key):
			continue
		var ci = int(gi / SLOTS_PER_CHAIN)
		var channel = gi % SLOTS_PER_CHAIN
		# Chains are created lazily: a map where only slot 4's layer has flagged
		# paths still needs mask chain 1, but not chain 0.
		while _mask_chains.size() <= ci:
			_mask_chains.append(null)
		if _mask_chains[ci] == null:
			_mask_chains[ci] = _make_mask_chain(vp_size)
		var root = _mask_chains[ci]["root"]

		var chan_color = [Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)][channel]
		for path in by_layer[layer_key]:
			var inset = float(path_tagging.get_config(path).get("mask_inset", 5.0))
			# A path IS a Line2D; a wall's art lives in its child Line2D
			# segments (already portal-gapped). Copy whichever carries the art.
			for src in _art_lines(path):
				# Same offscreen twin the ART FOOTPRINT uses, so mask and
				# footprint cannot disagree about where the art is.
				# MaskChannel.shader turns its alpha into this slot's channel.
				var copy = _copy_art_line(src)
				var mat = ShaderMaterial.new()
				mat.shader = _mask_shader
				mat.set_shader_param("channel", chan_color)
				# Per-path "Shadow inset", as an ALPHA EROSION across the strip.
				# NEVER as a width change: with TILE texture mode the tiling
				# count derives from the width, so shrinking it rescaled the art
				# along the path — the mask slid lengthwise and the visible
				# shadow boundary moved with it. UV.y spans the width, so
				# uv units = px / width.
				mat.set_shader_param("inset_uv", inset / max(1.0, float(src.width)))
				copy.material = mat
				root.add_child(copy)
				copied += 1
		matched += 1
		outputlog("art mask slot %d/layer %d -> chain %d channel %s, %d path(s)" % [
			gi, layer_key, ci, ["R", "G", "B"][channel], by_layer[layer_key].size()], 0)

	# Flagged paths on layers with no shadow group mask nothing; say so once so a
	# checkbox that seems inert is explainable from the log.
	for layer_key in by_layer.keys():
		var found = false
		for g in _groups:
			if int(round(g["layer"])) == layer_key:
				found = true
				break
		if not found:
			outputlog("art mask: %d flagged path(s) on layer %d, which has no caster group — no shadow to mask there" % [
				by_layer[layer_key].size(), layer_key], 0)

	if copied > 0:
		outputlog("art mask built: %d path(s) across %d layer(s), %d mask target(s)" % [
			copied, matched, _mask_chain_count()], 0)

# SHADOW BLOCKERS ("Stops outside shadows"). Rasterises each flagged path/
# wall's strip — full width, open portals cut out, same geometry the wall mode
# uses — as solid white into one binary field-sized target. The march samples
# it each step and stops on crossing, so shadow sources beyond a blocker never
# reach the near side (the house between cliffs keeps its floor lit), while
# open doors let the outside shadow spill through the gap. Non-physical by
# design; see the `blocks` config comment in PathTagging.
func _build_blockers(vp_size: Vector2):
	var nodes = path_tagging.get_blocker_nodes()
	if nodes.size() == 0:
		return
	_blocker = _make_mask_chain(vp_size)
	var drawn = 0
	for node in nodes:
		# Full width (inset 0): a blocker should stop shadows at the wall's
		# footprint, and a slightly generous edge also guards against the
		# march's growing stride stepping over a thin strip.
		# Portal gaps for every WALL node (one-sided walls included — their
		# strip still has doors) and for paths in Wall mode. A path on Side
		# A/B is a terrain step and portals must not touch the blocker
		# (see _path_strip_polygons).
		var gaps = path_tagging.is_wall_node(node) or int(path_tagging.get_config(node).get("side", 0)) == 2
		for poly in _path_strip_polygons(node, 0.0, gaps):
			var mesh = _make_polygon_mesh(poly, Color(1, 1, 1, 1))
			if mesh == null:
				continue
			var mi = MeshInstance2D.new()
			mi.mesh = mesh
			_blocker["root"].add_child(mi)
			drawn += 1
	outputlog("shadow blockers: %d node(s) -> %d strip piece(s)" % [nodes.size(), drawn], 0)

func get_blocker_texture():
	if _blocker == null or _blocker["vp"] == null or not is_instance_valid(_blocker["vp"]):
		return null
	return _blocker["vp"].get_texture()

# The Line2D nodes that carry a caster's visible artwork: the node itself for
# paths, its direct Line2D children for walls (DD builds those per segment,
# with portal gaps already cut).
func _art_lines(node) -> Array:
	if node is Line2D:
		return [node]
	var out = []
	for child in node.get_children():
		if child is Line2D:
			out.append(child)
	return out

# An offscreen twin of one artwork Line2D, placed in world coordinates. The
# caller supplies the material. Both consumers of the trick share this: the
# per-layer ART MASK and the ART FOOTPRINT must agree texel-for-texel about
# where a path's art is, or the shadow would tuck under one boundary and start
# at another.
#
# `texture_mode` and friends are copied because they decide how DD stretches the
# texture along the line — get them wrong and the alpha edge lands somewhere
# else entirely. `antialiased` is copied only when asked: Godot fringes the
# WHOLE outline, inner edge included, which is harmless in a mask but sprinkles
# height into the field.
func _copy_art_line(src, copy_antialiased: bool = true) -> Line2D:
	var copy = Line2D.new()
	copy.points = src.points
	copy.width = src.width
	copy.texture = src.texture
	for prop in ["texture_mode", "joint_mode", "begin_cap_mode", "end_cap_mode",
		"round_precision", "sharp_limit"]:
		var val = src.get(prop)
		if val != null:
			copy.set(prop, val)
	if copy_antialiased:
		var aa = src.get("antialiased")
		if aa != null:
			copy.antialiased = aa
	else:
		copy.antialiased = false
	var curve = src.get("width_curve")
	if curve != null:
		copy.width_curve = curve
	# Alpha is what matters downstream; force full opacity so a semi-transparent
	# line still contributes its own footprint.
	copy.default_color = Color(1, 1, 1, 1)
	copy.position = src.global_position
	copy.rotation = src.global_rotation
	copy.scale = src.global_scale
	return copy

#########################################################################################################
## ART FOOTPRINT
#########################################################################################################
# Raise the ground under a contour path's own artwork to that path's height.
#
# THE BUG THIS FIXES. The fill polygon is built from the SPINE, but the art
# straddles it, so the outer half of every cliff texture stood over ground the
# field called low. A higher layer's shadow therefore crossed the lower cliff's
# art and drew a hard line across it, instead of staying hidden under the art
# and emerging at the texture's own alpha edge.
#
# ONLY CONTOUR PATHS. Wall nodes and paths in "Wall (both)" already rasterise a
# strip of the FULL art width, symmetric about the spine (_path_strip_polygons
# takes its half-width from the Line2D's width), so the asymmetry cannot arise
# for them and a second footprint would only fight the blur-safe widening.
func _has_art_footprint(path) -> bool:
	if not bool(sun_settings.get_sun().get("bake_art_elevation", true)):
		return false
	if path_tagging.is_wall_node(path):
		return false
	if int(path_tagging.get_config(path).get("side", 0)) == 2:
		return false
	return path is Line2D

func _art_half_width(path) -> float:
	var half = 0.0
	for line in _art_lines(path):
		var s = line.global_scale
		half = max(half, float(line.width) * 0.5 * max(abs(s.x), abs(s.y)))
	return half

# Lazily create this chain's footprint target. Lazy because a map of pure wall
# casters needs none, and a render target this size is not free.
func _ensure_art_target(chain: Dictionary, vp_size: Vector2) -> Node2D:
	if chain["art"] != null and is_instance_valid(chain["art"]):
		return chain["art_root"]
	var vp = Viewport.new()
	vp.size = vp_size
	vp.usage = Viewport.USAGE_2D
	vp.transparent_bg = true
	vp.disable_3d = true
	vp.render_target_v_flip = true
	vp.render_target_update_mode = Viewport.UPDATE_ONCE

	var root = Node2D.new()
	root.scale = Vector2(_vp_scale, _vp_scale)
	root.position = -_raster_rect.position * _vp_scale
	vp.add_child(root)
	global.Editor.add_child(vp)

	chain["art"] = vp
	chain["art_root"] = root
	return root

# Draw one contour path's artwork into its chain's footprint target, at its own
# height, in its own slot's channel. Returns the number of Line2D copies made.
func _draw_art_footprint(chain: Dictionary, slot: int, channel: int, path,
	height: float, vp_size: Vector2) -> int:

	if _artfoot_shader == null:
		return 0
	var lines = _art_lines(path)
	if lines.size() == 0:
		return 0
	var root = _ensure_art_target(chain, vp_size)
	var chan_color = [Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)][channel]
	var made = 0
	for src in lines:
		var copy = _copy_art_line(src, false)
		# No texture, or texture_mode = None (LineBuilder emits no UVs at all in
		# that mode): there is no alpha to threshold, and what DD draws is a
		# solid line of full width, so all of it raises ground.
		var tex_mode = src.get("texture_mode")
		var textured = src.texture != null and tex_mode != Line2D.LINE_TEXTURE_NONE
		var mat = ShaderMaterial.new()
		mat.shader = _artfoot_shader
		mat.set_shader_param("channel", chan_color)
		mat.set_shader_param("elevation", height / HEIGHT_DIVISOR)
		mat.set_shader_param("alpha_threshold", ART_ALPHA_THRESHOLD)
		mat.set_shader_param("use_texture", 1.0 if textured else 0.0)
		copy.material = mat
		root.add_child(copy)
		made += 1
	if made > 0 and height > _slot_art_max[slot]:
		_slot_art_max[slot] = height
	return made

func _make_mask_chain(vp_size: Vector2) -> Dictionary:
	var vp = Viewport.new()
	vp.size = vp_size
	vp.usage = Viewport.USAGE_2D
	vp.transparent_bg = true
	vp.disable_3d = true
	vp.render_target_v_flip = true
	vp.render_target_update_mode = Viewport.UPDATE_ALWAYS

	var root = Node2D.new()
	root.scale = Vector2(_vp_scale, _vp_scale)
	root.position = -_raster_rect.position * _vp_scale
	vp.add_child(root)
	global.Editor.add_child(vp)
	return {"vp": vp, "root": root}

func _mask_chain_count() -> int:
	var n = 0
	for mc in _mask_chains:
		if mc != null:
			n += 1
	return n

# The mask texture for one chain, or null if that chain has no flagged paths —
# which is how ShadowRenderer knows to switch the shader's mask off.
func get_mask_texture(chain_index: int):
	if chain_index < 0 or chain_index >= _mask_chains.size():
		return null
	var mc = _mask_chains[chain_index]
	if mc == null or mc["vp"] == null or not is_instance_valid(mc["vp"]):
		return null
	return mc["vp"].get_texture()

# Nested render targets need a few frames to propagate raster -> smooth -> bake.
# ShadowRenderer drives these around its own bake window.
func thaw():
	for vp in _all_viewports():
		vp.render_target_update_mode = Viewport.UPDATE_ALWAYS

func freeze():
	for vp in _all_viewports():
		vp.render_target_update_mode = Viewport.UPDATE_DISABLED

func _all_viewports() -> Array:
	var out = []
	for chain in _chains:
		for key in ["raster", "art", "blur_h", "blur_v"]:
			var vp = chain[key]
			if vp != null and is_instance_valid(vp):
				out.append(vp)
	for mc in _mask_chains:
		if mc != null and mc["vp"] != null and is_instance_valid(mc["vp"]):
			out.append(mc["vp"])
	if _blocker != null and _blocker["vp"] != null and is_instance_valid(_blocker["vp"]):
		out.append(_blocker["vp"])
	return out

func get_raster_rect():
	return _raster_rect

func get_vp_scale() -> float:
	return _vp_scale

# The smoothed field for one chain, which is what the march must consume. Falls
# back to the raw rasterisation only if the smoothing shader failed to load.
# Returns null for a chain that does not exist, which is how ShadowRenderer knows
# whether to enable the shader's second field.
func get_field_texture(chain_index: int):
	if chain_index < 0 or chain_index >= _chains.size():
		return null
	var chain = _chains[chain_index]
	if chain["blur_v"] != null and is_instance_valid(chain["blur_v"]):
		return chain["blur_v"].get_texture()
	if chain["raster"] != null and is_instance_valid(chain["raster"]):
		return chain["raster"].get_texture()
	return null

# Chain 0's smoothed field. Kept as the "is there anything to render" probe.
func get_texture():
	return get_field_texture(0)

# The raw field of one chain, for the debug overlay and the histogram.
func get_raw_texture(chain_index: int = 0):
	if chain_index < 0 or chain_index >= _chains.size():
		return null
	var vp = _chains[chain_index]["raster"]
	if vp == null or not is_instance_valid(vp):
		return null
	return vp.get_texture()

func _teardown_viewport():
	for chain in _chains:
		for key in ["blur_v", "blur_h", "art", "raster"]:
			var vp = chain[key]
			if vp != null and is_instance_valid(vp):
				if vp.get_parent() != null:
					vp.get_parent().remove_child(vp)
				vp.queue_free()
	for mc in _mask_chains:
		if mc != null and mc["vp"] != null and is_instance_valid(mc["vp"]):
			if mc["vp"].get_parent() != null:
				mc["vp"].get_parent().remove_child(mc["vp"])
			mc["vp"].queue_free()
	if _blocker != null and _blocker["vp"] != null and is_instance_valid(_blocker["vp"]):
		if _blocker["vp"].get_parent() != null:
			_blocker["vp"].get_parent().remove_child(_blocker["vp"])
		_blocker["vp"].queue_free()
	_chains = []
	_mask_chains = []
	_blocker = null
	_groups = []
	_slot_art_max = []
	_side_suppress = {}
	_viewport_count = 0

#########################################################################################################
## DEBUG VIEW
#########################################################################################################
# Shows the raw field over the map so the fill regions can be checked by eye
# before anything depends on them. Amplified, since one tier is only 1/16 of a
# channel and would otherwise be nearly black.
#
# Now that each layer group owns a colour channel this overlay is also a group
# check: slot 0 shows RED, slot 1 GREEN, slot 2 BLUE, and a second chain (slots
# 3..5) is added on top with ADD blending. Grey means several layers stacked.

func _refresh_debug_sprite():
	_remove_debug_sprite()
	if not bool(sun_settings.get_sun().get("debug_height_field", false)):
		return
	if _map_rect == null or _chains.size() == 0:
		return
	var level = global.World.GetCurrentLevel()
	if level == null:
		outputlog("no current level — debug sprite not shown", 0)
		return

	for ci in range(_chains.size()):
		# THE FIELD THE MARCH READS — blurred, and with the art footprint already
		# combined in. It used to show the raw fill raster, which hid two whole
		# classes of defect from view: anything the footprint contributes (a
		# separate target, combined downstream) and anything the blur does to a
		# thin feature. A debug view that does not show what the consumer
		# consumes is worse than none — it was showing a clean field under an
		# artefact and sending the diagnosis to the wrong half of the pipeline.
		var tex = get_field_texture(ci)
		if tex == null:
			continue
		var sprite = Sprite.new()
		sprite.name = DEBUG_SPRITE_NAME + str(ci)
		sprite.texture = tex
		sprite.centered = false
		sprite.position = _raster_rect.position
		sprite.scale = Vector2(1.0 / _vp_scale, 1.0 / _vp_scale)
		# Above map content (DeferredLighting is 1000) but BELOW DD's Texts layer
		# (4094 absolute) and its tool/selection widgets — at 4096 the overlay
		# painted over the selection handles, which made paths uneditable-looking
		# while the debug view was on.
		sprite.z_as_relative = false
		sprite.z_index = 1500
		sprite.modulate = Color(HEIGHT_DIVISOR / 4.0, HEIGHT_DIVISOR / 4.0, HEIGHT_DIVISOR / 4.0, 1.0)
		if ci > 0:
			var mat = CanvasItemMaterial.new()
			mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
			sprite.material = mat
		level.add_child(sprite)
		_debug_sprites.append(sprite)
		# Log the full placement chain. Position/scale bugs here are invisible in
		# code review but obvious in numbers: sprite coverage should equal the map
		# rect exactly.
		var tex_size = tex.get_size()
		outputlog("debug sprite chain %d (slots %d..%d): tex=%s pos=%s scale=%s -> covers %s ; raster rect %s (each tier = 1/%d of a channel, amplified %.1fx)" % [
			ci, ci * SLOTS_PER_CHAIN, ci * SLOTS_PER_CHAIN + SLOTS_PER_CHAIN - 1,
			str(tex_size), str(sprite.position), str(sprite.scale),
			str(Vector2(tex_size.x * sprite.scale.x, tex_size.y * sprite.scale.y)),
			str(_raster_rect.size), int(HEIGHT_DIVISOR), HEIGHT_DIVISOR / 4.0], 0)
	outputlog("debug overlay shows the SMOOTHED field the march reads (fills + art footprint, blurred)", 1)

func _remove_debug_sprite():
	for sprite in _debug_sprites:
		if sprite != null and is_instance_valid(sprite):
			if sprite.get_parent() != null:
				sprite.get_parent().remove_child(sprite)
			sprite.queue_free()
	_debug_sprites = []

func set_debug_visible(_on: bool):
	_refresh_debug_sprite()

# Drop the overlay and the render targets entirely. Configuration is untouched, so
# rebuild() restores everything.
func disable():
	_remove_debug_sprite()
	_teardown_viewport()
