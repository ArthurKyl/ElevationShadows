#########################################################################################################
##
## SILHOUETTE — an occupancy sample of an asset's opaque pixels
##
#########################################################################################################
# Object pattern shadows need to know how wide an object actually is, square-on
# to the sun. The texture rect will not do: every DD asset is a rectangular
# texture with the art floating in a transparent margin, so the rect sizes the
# shadow to the empty square. Measured across built-in and pack assets, the rect
# oversizes by 1.00x (a built-in crate, filled edge to edge) up to 1.84x.
#
# So: reduce the opaque region to occupancy CELLS once per texture, cached by
# resource path and shared by every prop using that asset, and project them per
# rebuild. Only the EXTREMES of those cells are read now — the traced march asks
# TracedShadow.shader for the object's real shape per pixel, straight from the
# object's own texture, so nothing here has to represent a concavity any more.
# A hull would therefore serve equally well; the cells stay because they work,
# they are cached, and churning a working path back would buy nothing. A long
# object still narrows on its own as the sun swings round to look along it.
#
# Everything maps through sprite.get_global_transform(). That single matrix
# composes prop scale, prop rotation, position and any sprite offset, so this
# file never has to know where DD keeps an object's user-set size. (It keeps it
# in node.scale — verified — but the transform is what actually puts pixels on
# the map, and it tracked a 4.0 -> 1.609 handle-drag exactly.)
#
# Every stage is fallible and every failure falls back to the texture rect with
# a level-0 log naming the object. A silently mis-sized shadow reads as a
# rendering bug; a logged one reads as a missing measurement.

var global
var core = null

# Cap the scan so a 2048x2048 asset costs about what a 256x256 one does. A texel
# or two of error is invisible at shadow scale.
const TARGET_SAMPLES = 32768
# Occupancy resolution. The shape is reduced to at most this many cells per axis
# and every cell containing a drawn texel is kept, so a 2 px lattice bar still
# registers as long as the sample step lands in it.
const GRID_MAX = 64
# Above this alpha, the artist drew something here. Deliberately low: soft edges
# and faint scatter (a pebble asset is only ~8% opaque) still count.
const ALPHA_VISIBLE = 0.02

# texture key -> Array of Vector2, occupancy cell centres in sprite-local px
# (centred on the texture, because DD sprites are centred with zero offset).
var _cache = {}

func outputlog(msg, level = 0):
	if core != null:
		core.outputlog("[Silhouette] " + str(msg), level)

func initialise():
	_cache = {}

# Drop cached samples. Call if assets are ever reloaded under us; cheap to re-extract.
func clear_cache():
	var n = _cache.size()
	_cache = {}
	if n > 0:
		outputlog("cache cleared (%d texture(s))" % n, 1)

# The silhouette's extent along `perp` and its extremes along `dirv`, all in
# WORLD px: {lo, hi, trail, lead}. null when the node has no usable sprite — the
# caller skips such an object rather than guessing a size for it.
#
# Extent ONLY. This used to also report the downsun-most point in each of `cols`
# columns across the width, so the renderer could emit one strip per column. That
# streaked: each strip faded from its OWN column's edge, so two neighbours
# covering the same patch of ground computed different darkness and every seam
# became a visible step. TracedShadow.shader now reads the object's real shape
# per pixel out of the object's own texture, so the shape never has to be
# discretised here at all and only the extent is left to report.
#
# `dirv` and `perp` MUST be orthonormal. SunSettings.get_shadow_direction()
# returns a normalised vector and perp is its rotation, so the only caller
# satisfies this by construction.
func profile(node, dirv: Vector2, perp: Vector2):
	if node == null or not is_instance_valid(node):
		return null
	var sprite = _get_sprite(node)
	if sprite == null:
		outputlog("object %s: no Sprite child — cannot measure, not casting" % str(core.get_node_id(node)), 0)
		return null
	var pts = _points_for(sprite, node)
	if pts.size() == 0:
		return null
	var xf = sprite.get_global_transform()

	# One transform per cached point, reduced straight to the four extremes:
	# lo/hi across the sun, trail/lead along it. Nothing is kept, so a 4096-cell
	# asset no longer builds a throwaway array on every settled-sun rebuild.
	var lo = INF
	var hi = -INF
	var trail = INF
	var lead = -INF
	for p in pts:
		var wp = xf.xform(p)
		var dp = wp.dot(perp)
		var dd = wp.dot(dirv)
		if dp < lo:
			lo = dp
		if dp > hi:
			hi = dp
		if dd < trail:
			trail = dd
		if dd > lead:
			lead = dd

	return {"lo": lo, "hi": hi, "trail": trail, "lead": lead}

# ShadowRenderer already relies on prop.get("Sprite") for the ghost prop, and the
# probe confirmed it on every object tested. The child scan is a cheap safety net
# for node kinds that turn out to differ.
func _get_sprite(node):
	var sprite = node.get("Sprite")
	if sprite != null and is_instance_valid(sprite):
		return sprite
	for child in node.get_children():
		if child is Sprite:
			return child
	return null

# The world -> texture-UV map for an object's own art, for the traced shadow
# march: a world point `w` maps to uv = io + ix * w.x + iy * w.y. null when the
# node has no usable sprite or texture, which the caller treats as "cannot cast".
#
# Derivation: the sprite's global transform maps sprite-local px to world, so
# its affine inverse maps back. DD sprites are centred with offset (0,0) — probed
# on 12 assets, and the same assumption _extract already makes — so local (0,0)
# is the texture's middle and uv = (local + size/2) / size.
#
# Godot 3's Transform2D stores its basis as COLUMNS: xform(v) is
# `x * v.x + y * v.y + origin`, with `x` and `y` Vector2s. So for the inverse,
# local = inv.x * w.x + inv.y * w.y + inv.origin, and substituting into the line
# above gives exactly the three vectors returned here. The `/ size` is Godot's
# component-wise Vector2 divide (uv.x by the width, uv.y by the height), and it
# has to be applied to each term separately — which is why `+ half` rides on the
# origin term alone. Folding the division in this way keeps the shader's inner
# loop to one multiply-add.
func object_uv_map(node):
	if node == null or not is_instance_valid(node):
		return null
	var sprite = _get_sprite(node)
	if sprite == null:
		return null
	var tex = sprite.texture
	if tex == null:
		return null
	var size = tex.get_size()
	if size.x <= 0.0 or size.y <= 0.0:
		return null
	var inv = sprite.get_global_transform().affine_inverse()
	var half = size * 0.5
	return {
		"tex": tex,
		"ix": inv.x / size,
		"iy": inv.y / size,
		"io": (inv.origin + half) / size,
	}

func _points_for(sprite, node) -> Array:
	var tex = sprite.texture
	if tex == null:
		outputlog("object %s: sprite has no texture" % str(core.get_node_id(node)), 0)
		return []
	# resource_path was populated on every asset probed; the RID key is a
	# fallback so a runtime-built texture still caches instead of re-extracting
	# on every rebuild.
	var key = str(tex.resource_path)
	if key == "":
		key = "rid:%d" % tex.get_rid().get_id()
	if _cache.has(key):
		return _cache[key]
	var pts = _extract(tex, key)
	_cache[key] = pts
	return pts

func _extract(tex, key: String) -> Array:
	var t0 = OS.get_ticks_msec()
	var size = tex.get_size()
	var img = null
	if tex.has_method("get_data"):
		img = tex.get_data()
	if img == null:
		outputlog("'%s': get_data() gave nothing — falling back to the texture RECT, so this asset's shadow is sized to its whole square" % key, 0)
		return _rect_points(size.x, size.y)
	# Uncompressed RGBA8 on everything probed, but a compressed image cannot be
	# sampled with get_pixel, so guard rather than assume.
	if img.is_compressed():
		if img.decompress() != OK:
			outputlog("'%s': decompress() failed — falling back to the texture RECT" % key, 0)
			return _rect_points(size.x, size.y)
	var w = img.get_width()
	var h = img.get_height()
	if w <= 0 or h <= 0:
		outputlog("'%s': image is %dx%d — falling back to the texture RECT" % [key, w, h], 0)
		return _rect_points(size.x, size.y)

	var step = int(max(1.0, floor(sqrt(float(w * h) / float(TARGET_SAMPLES)))))
	# Reduce the shape to occupancy cells: a cheap, cached sample of the art
	# used only to get the object's EXTENT. TracedShadow.shader reads the
	# object's real shape per pixel, straight from its own texture, so
	# nothing here has to represent a concavity or an inward-facing edge any
	# more — a hull would serve this job just as well. Cells stay because
	# they already work and are cached; swapping a working path for no gain
	# buys nothing. Marking a cell from ANY sampled opaque texel in it means
	# a thin lattice bar at the shape's edge still survives the subsampling
	# and is not lost from the extent.
	var cells_x = int(min(float(GRID_MAX), ceil(float(w) / float(step))))
	var cells_y = int(min(float(GRID_MAX), ceil(float(h) / float(step))))
	cells_x = int(max(1, cells_x))
	cells_y = int(max(1, cells_y))
	var occupied = {}
	var opaque = 0
	img.lock()
	var y = 0
	while y < h:
		var x = 0
		while x < w:
			if img.get_pixel(x, y).a > ALPHA_VISIBLE:
				opaque += 1
				var cx = int(clamp(float(x) / float(w) * float(cells_x), 0.0, float(cells_x - 1)))
				var cy = int(clamp(float(y) / float(h) * float(cells_y), 0.0, float(cells_y - 1)))
				occupied[cy * cells_x + cx] = true
			x += step
		y += step
	img.unlock()

	if occupied.size() == 0:
		outputlog("'%s': fully transparent — falling back to the texture RECT" % key, 0)
		return _rect_points(size.x, size.y)

	# Cell centres, in sprite-local px. DD sprites are centred with offset (0,0),
	# so a texture pixel (px, py) sits at local (px - w/2, py - h/2).
	#
	# The key is cy * cells_x + cx with cx strictly inside 0..cells_x-1, so it is
	# a bijection onto the cell grid — no two cells can collide on one key, and
	# the decode below is exact. `%` and `/` on two ints are integer ops in
	# GDScript 3 (int / int truncates), so the int() is belt and braces, not a
	# conversion. `key_i`, not `key`: `key` is this function's own parameter and
	# GDScript var scoping is function-level.
	var half = Vector2(float(w) * 0.5, float(h) * 0.5)
	var out = []
	for key_i in occupied.keys():
		var cx2 = key_i % cells_x
		var cy2 = int(key_i / cells_x)
		out.append(Vector2(
			(float(cx2) + 0.5) / float(cells_x) * float(w),
			(float(cy2) + 0.5) / float(cells_y) * float(h)) - half)
	outputlog("'%s': %dx%d, step %d, %d opaque sample(s) -> %d of %dx%d occupancy cell(s) in %d ms" % [
		key, w, h, step, opaque, out.size(), cells_x, cells_y, OS.get_ticks_msec() - t0], 1)
	return out

# The whole texture square as a filled grid of points, centred. Used whenever
# measurement fails, so a shadow is still cast — just sized to the square, which
# the width adjust can pull back in.
#
# GRID_MAX is the occupancy grid's own resolution, so this fallback is exactly as
# dense as a measured asset and nothing downstream can tell the two apart. Do not
# reduce it. Back when the points were bucketed into columns, a coarser grid here
# left every column past the grid empty and a prop wider than one grid square
# cast a comb of thin bars instead of the solid square this promises — a real,
# fixed bug. Only the extremes are read now, so four corners would in fact do;
# the filled grid stays because it is extracted once and cached, and unpicking a
# fixed bug's fix buys nothing.
func _rect_points(w: float, h: float) -> Array:
	var out = []
	var n = GRID_MAX
	var half = Vector2(w * 0.5, h * 0.5)
	for iy in range(n):
		for ix in range(n):
			out.append(Vector2(
				(float(ix) + 0.5) / float(n) * w,
				(float(iy) + 0.5) / float(n) * h) - half)
	return out
