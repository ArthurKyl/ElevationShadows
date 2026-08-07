#########################################################################################################
##
## SHADOW RENDERER — one sprite PER CASTER LAYER, one shader, per-pixel sun march
##
#########################################################################################################
# The whole map's shadow is a set of Sprites textured with the height field,
# running ElevationShadow.shader — one per distinct caster layer.
#
# Why per pixel: shadow is decided per PIXEL, so the result is continuous by
# construction. The abandoned mesh version made an independent decision per path
# point, and neighbouring points could disagree wildly — producing the hard
# diagonal clip lines, pinholes, and shadow leaking inside ridges that five rounds
# of threshold tuning never resolved.
#
# Why per layer, and why the shadow node is a GHOST PROP inside DD's Objects
# container at z = ITS OWN LAYER (all verified against the disassembled
# Dungeondraft.dll, 1.2.0.1):
#
#   * Godot draws by z bucket; ties inside a bucket go by tree order. A layer's
#     shadow at z = layer is above every LOWER layer's art (the 400 shadow darkens
#     the 200 cliff texture) and above untiered z-0 content (WaterMesh/
#     PatternShapes/Pathways/Objects containers), which the old `layer - 1`
#     placement slid underneath — that was the "everything on layer 0 must be sent
#     to Below Water" bug.
#   * DD's Bring to front / Send to back (SelectTool::BringToFront, NodeEx::
#     MoveToFront/Back) are sibling reorders via parent.MoveChild. Putting the
#     shadow node INSIDE Level.Objects at the same z as same-layer objects makes
#     those buttons work on it natively: an object in front of the shadow node is
#     lit, behind it is shadowed — per object, no mod UI.
#   * The node must be a real Prop: SelectTool::SelectThingsInsideBox does a
#     throwing castclass Prop on every Objects child, so a plain Sprite in there
#     breaks box selection. Objects::CreateObject is just `new Prop()` + AddChild
#     and is callable from GDScript.
#   * The ghost is invisible to everything else, verified path by path:
#       save    — Objects::Save skips children without `node_id` meta, silently;
#       load    — Objects::Load recreates objects in saved sibling order, so the
#                 user's front/back arrangement round-trips (the ghost's own place
#                 among them is restored from ModMapData, see ORDER PERSISTENCE);
#       picking — hover/click uses Objects.QuickSearchBuckets, and nothing adds a
#                 prop to it except explicit tool actions (ObjectTool::Confirm,
#                 LoadObject...), so a CreateObject'd prop is never found;
#       box-sel — IsNodeLocked reads the `locked` meta; the ghost sets it, and
#                 normal box select skips locked nodes;
#       shadow  — Prop's built-in drop shadow only gets a texture via SetTexture/
#                 UpdateShadow, which the mod never calls (it textures the child
#                 Sprite directly);
#       export  — Prop::HandleExport is just CanvasItem.Update(), a redraw.
#
#   * Same-layer PATHS cannot get the button treatment: they live in the Pathways
#     container, which draws before Objects in the same z bucket, and MoveChild
#     cannot cross parents. Their control is the per-path "Art above shadow" mask
#     (PathTagging + HeightField), which exempts flagged art from ITS OWN layer's
#     shadow only — higher layers' shadows still darken it, so the per-layer mask
#     does not re-introduce the old global-mask bug.
#
# The mod sets z ONLY on nodes it creates. It never writes z_index/ZIndex to a
# caster path, a user's object, or a DD container: the user's layering is
# deliberate and is theirs to change through DD's Layer dropdown.
#
# It is also cheap to adjust. Sun direction, height, strength and diffusion are
# all shader uniforms, so changing them is a parameter write, not a geometry
# rebuild. Only a change to the contours themselves needs the field
# re-rasterised.

var global
var core = null
var sun_settings = null
var path_tagging = null
var height_field = null

const PROP_NAME = "ElevationShadowsRender"

# DD's layer z values, from Level::CreateDefaultUserLayers / LockedLayers:
#   Below Ground -400, Below Water -100, User Layer 1..4 = 100/200/300/400,
#   Above Walls 700, Above Roofs 900.
# Containers: FloorTileMap -1000, Terrain -500, CaveMesh -300, FloorShapes -200,
#   WaterMesh/PatternShapes/MaterialMeshes/Pathways/Objects 0, Portals 500,
#   Walls 600, Roofs 800, DeferredLighting 1000, Texts 4094 (absolute).
# The ghost prop is z_as_relative inside Objects (z 0), so z_index = layer puts
# it in exactly the layer's bucket: above all lower layers and all z-0 content,
# tied with its own layer — where tree order (Pathways < Objects, sibling index
# inside Objects) decides, which is the whole point.

# Diffusion maps to the sun's angular radius. A real sun is ~0.27 degrees, but
# this is an art control, so the usable range is far wider.
const SPREAD_MIN_DEG = 0.5
const SPREAD_MAX_DEG = 20.0

# Marching one field texel per step is the useful limit; more steps just resample
# the same texels. Capped to match MAX_STEPS in the shader.
const MAX_MARCH_STEPS = 512
const MIN_MARCH_STEPS = 32

# Target march stride, in height-field texels. Below ~2 the march starts
# resampling the same texels; much above it, thin curved bands of pixels sample
# just past an occluder edge and read as unshadowed lines.
const TARGET_STRIDE_TEXELS = 1.5

# Resolution of the baked shadow. Matching the height field avoids magnifying the
# bake on top of the field's own scaling — at 1024 against a 2048 field the result
# was stretched ~12x on screen, which coarsened every edge. Doubled during export
# in lockstep with the field (Core toggles `export_boost` around the export
# window) so a ~4500 px 100-PPI export is served nearly 1:1.
const BAKE_MAX_DIM = 2048.0
const EXPORT_BAKE_MAX_DIM = 4096.0
var export_boost = false

func _bake_cap() -> float:
	return EXPORT_BAKE_MAX_DIM if export_boost else BAKE_MAX_DIM

var _shader = null
var _display_shader = null

# One entry per caster layer, ascending:
#   {"slot":int, "layer":float, "z":int, "bake_vp":Viewport, "bake_sprite":Sprite,
#    "material":ShaderMaterial, "prop":Prop (ghost, inside Level.Objects),
#    "sprite":Sprite (the prop's own child Sprite, textured with the bake)}
#
# Offscreen bakes. Running the march per screen pixel per frame is unusably slow
# (256+ texture fetches per pixel, every frame). Instead the march runs ONCE into
# each group's viewport whenever settings change, and the visible sprite just
# displays the result — so panning and zooming cost nothing.
var _groups = []

func outputlog(msg, level = 0):
	if core != null:
		core.outputlog("[Render] " + str(msg), level)

#########################################################################################################
## INIT
#########################################################################################################

func initialise():
	_shader = ResourceLoader.load(global.Root + "shaders/ElevationShadow.shader", "Shader", true)
	if _shader == null:
		outputlog("FATAL: shaders/ElevationShadow.shader failed to load", 0)
		return
	_display_shader = ResourceLoader.load(
		global.Root + "shaders/ShadowDisplay.shader", "Shader", true)
	if _display_shader == null:
		outputlog("FATAL: shaders/ShadowDisplay.shader failed to load", 0)
		return
	_pattern_shader = ResourceLoader.load(
		global.Root + "shaders/PatternShadow.shader", "Shader", true)
	if _pattern_shader == null:
		outputlog("WARNING: PatternShadow.shader failed to load — no portal beams/patterns", 0)
	_make_pattern_textures()
	outputlog("shaders loaded", 0)

#########################################################################################################
## PORTAL LIGHT PATTERNS
#########################################################################################################
# Generated at runtime — no asset files. Index 0 (None) is a plain opening.
# Alpha is the blocker: opaque parts shade, transparent parts pass light. The
# same contract a future custom-asset option would use ("anything that isn't
# 0% opacity blocks at full strength").

var _pattern_shader = null
var _pattern_textures = []

func _make_pattern_textures():
	_pattern_textures = [null]
	for idx in range(1, 6):
		var img = Image.new()
		img.create(64, 64, false, Image.FORMAT_RGBA8)
		img.lock()
		for y in range(64):
			for x in range(64):
				var a = _pattern_alpha(idx, (x + 0.5) / 64.0, (y + 0.5) / 64.0)
				img.set_pixel(x, y, Color(1, 1, 1, a))
		img.unlock()
		var tex = ImageTexture.new()
		tex.create_from_image(img, Texture.FLAG_REPEAT | Texture.FLAG_FILTER)
		_pattern_textures.append(tex)
	outputlog("%d light patterns generated" % (_pattern_textures.size() - 1), 1)

# u across the span, v UP the opening's face; one tile = `tile` ft.
func _pattern_alpha(idx: int, u: float, v: float) -> float:
	if idx == 1:
		# Bars — portcullis / gate.
		return 1.0 if abs(u - 0.5) < 0.20 else 0.0
	if idx == 2:
		# Window panes — frame lines tile into the classic cross grid.
		return 1.0 if (u < 0.08 or u > 0.92 or v < 0.08 or v > 0.92) else 0.0
	if idx == 3:
		# Diamond lattice — leaded glass.
		var s = fposmod(u + v, 1.0)
		var t = fposmod(u - v, 1.0)
		return 1.0 if (abs(s - 0.5) < 0.08 or abs(t - 0.5) < 0.08) else 0.0
	if idx == 4:
		# Plus holes — solid gate pierced by + shaped openings.
		var du = abs(u - 0.5)
		var dv = abs(v - 0.5)
		if (du < 0.17 and dv < 0.40) or (dv < 0.17 and du < 0.40):
			return 0.0
		return 1.0
	# Checker — heavy grate.
	return 1.0 if ((u < 0.5) != (v < 0.5)) else 0.0

#########################################################################################################
## BUILD
#########################################################################################################

func clear():
	# The ghost props are about to be destroyed; capture where the user's
	# front/back arrangement left them first, so the rebuild puts each one back
	# among the same objects.
	sync_order_store()
	for g in _groups:
		var prop = g["prop"]
		if prop != null and is_instance_valid(prop):
			if prop.get_parent() != null:
				prop.get_parent().remove_child(prop)
			prop.queue_free()
		var vp = g["bake_vp"]
		if vp != null and is_instance_valid(vp):
			if vp.get_parent() != null:
				vp.get_parent().remove_child(vp)
			vp.queue_free()
	_groups = []

func rebuild():
	clear()
	if _shader == null or _display_shader == null:
		return
	if core != null and core.get_mode() == core.MODE_OFF:
		return

	var group_count = height_field.get_group_count()
	if group_count <= 0:
		# No enabled casters -> no groups -> no sprites at all. Deliberately NOT a
		# fallback sprite at some guessed z: the old single-sprite code derived its z
		# from get_max_caster_layer(), which returns 0.0 for an empty caster set and
		# parked the sprite at z=1 underneath everything.
		outputlog("0 caster layer groups — nothing rendered", 0)
		return

	var tex_a = height_field.get_field_texture(0)
	if tex_a == null:
		outputlog("height field has no texture — nothing to render", 0)
		return
	# Chain 1 carries slots 3..5 and only exists when there are more than three
	# caster layers. When absent, the shader's field_b is bound to field A and
	# switched off with use_field_b = 0, so no extra render target is allocated and
	# no sampler is left unbound.
	var tex_b = height_field.get_field_texture(1)
	var have_b = tex_b != null
	if not have_b:
		tex_b = tex_a

	var raster_rect = height_field.get_raster_rect()
	if raster_rect == null:
		outputlog("height field has no raster rect — nothing to render", 0)
		return
	var vp_scale = height_field.get_vp_scale()
	if vp_scale <= 0.0:
		return

	var level = global.World.GetCurrentLevel()
	if level == null:
		outputlog("no current level — nothing to render", 0)
		return
	# Level.Objects, the same container DD's object tools operate on. The ghost
	# props MUST live inside it — Bring to front / Send to back are sibling
	# reorders (parent.MoveChild), so they can only order an object against a
	# shadow that shares the parent.
	var objects = level.get("Objects")
	if objects == null:
		outputlog("FATAL: Level.Objects not found — shadows cannot be placed", 0)
		return

	# Smooth height interpolation gives smoother shadow edges than nearest.
	tex_a.flags = Texture.FLAG_FILTER
	if have_b:
		tex_b.flags = Texture.FLAG_FILTER

	var field_size = tex_a.get_size()
	var bake_scale = min(1.0, _bake_cap() / max(field_size.x, field_size.y))
	var bake_size = Vector2(
		max(4.0, floor(field_size.x * bake_scale)),
		max(4.0, floor(field_size.y * bake_scale)))

	for gi in range(group_count):
		var layer = height_field.get_group_layer(gi)

		var material = ShaderMaterial.new()
		material.shader = _shader

		# --- Offscreen bake: run this layer's march once, into a texture. ---
		var bake_vp = Viewport.new()
		bake_vp.size = bake_size
		bake_vp.usage = Viewport.USAGE_2D
		bake_vp.transparent_bg = true
		bake_vp.disable_3d = true
		# Both this and the height viewports need the flip, so orientation survives
		# being rendered through several render targets.
		bake_vp.render_target_v_flip = true
		# UPDATE_ALWAYS briefly, then frozen by _freeze_bake(). A single UPDATE_ONCE
		# is a gamble here: this viewport samples the height field's render targets,
		# and if it happens to render first it bakes from an empty field.
		bake_vp.render_target_update_mode = Viewport.UPDATE_ALWAYS

		var bake_sprite = Sprite.new()
		bake_sprite.texture = tex_a
		bake_sprite.centered = false
		bake_sprite.position = Vector2.ZERO
		bake_sprite.scale = Vector2(bake_scale, bake_scale)
		bake_sprite.material = material
		bake_vp.add_child(bake_sprite)
		# Portal beam/pattern quads render into the same bake, ON TOP of the
		# march (additive into red). The root maps world px -> bake px so the
		# projector can think in world coordinates.
		var quad_root = Node2D.new()
		var qs = vp_scale * bake_scale
		quad_root.scale = Vector2(qs, qs)
		quad_root.position = -raster_rect.position * qs
		bake_vp.add_child(quad_root)
		# A Viewport is not a CanvasItem, so parking it here does not draw into the map.
		global.Editor.add_child(bake_vp)

		# --- Visible node: a ghost Prop in Level.Objects displaying the bake. ---
		var baked = bake_vp.get_texture()
		baked.flags = Texture.FLAG_FILTER

		var prop = objects.CreateObject(0)
		if prop == null:
			outputlog("FATAL: Objects.CreateObject returned null for layer %d" % int(layer), 0)
			bake_vp.queue_free()
			continue
		prop.name = "%s_L%d" % [PROP_NAME, int(layer)]
		# Box select skips nodes whose `locked` meta mismatches the alt-key state
		# (NodeEx::IsNodeLocked), so a locked ghost is not selectable normally.
		# No node_id meta is ever set, so Objects::Save skips it silently.
		prop.set_meta("locked", true)
		# RELATIVE z (the default, but be explicit): DD moves a reference level to
		# -2000 in compare mode, and an absolute z would ignore that.
		prop.z_as_relative = true
		prop.z_index = int(layer)

		# Texture the prop's own child Sprite directly. NOT Prop.SetTexture(),
		# which would also hand the texture to the built-in drop-shadow sprite.
		var sprite = prop.get("Sprite")
		if sprite == null:
			outputlog("FATAL: ghost prop has no Sprite child — DD internals changed?", 0)
			objects.remove_child(prop)
			prop.queue_free()
			bake_vp.queue_free()
			continue
		sprite.texture = baked
		sprite.centered = false
		sprite.position = raster_rect.position
		sprite.scale = Vector2(
			raster_rect.size.x / bake_size.x,
			raster_rect.size.y / bake_size.y)
		# Converts the baked red channel back into shadow alpha.
		var disp = ShaderMaterial.new()
		disp.shader = _display_shader
		disp.set_shader_param("shadow_color", Color(0, 0, 0, 1))
		sprite.material = disp

		# Put the ghost back where the user's front/back arrangement had it
		# (default: index 0 = every real object draws over the shadow = lit).
		_restore_prop_order(objects, prop, layer)

		_groups.append({
			"slot": gi,
			"layer": layer,
			"z": int(layer),
			"bake_vp": bake_vp,
			"bake_sprite": bake_sprite,
			"quad_root": quad_root,
			"material": material,
			"prop": prop,
			"sprite": sprite,
		})

	update_uniforms()

	var placement = PoolStringArray()
	for g in _groups:
		placement.append("slot %d: layer %d -> z %d, %d caster(s)" % [
			g["slot"], int(g["layer"]), g["z"],
			height_field.get_group_caster_count(g["slot"])])
	outputlog("built %d shadow sprite(s): %s" % [_groups.size(), placement.join(" | ")], 0)
	outputlog("render targets: %d height + %d bake = %d total (%d field chain(s), field %s, bake %s, sprite scale %.3f covering %s)" % [
		height_field.get_viewport_count(), _groups.size(),
		height_field.get_viewport_count() + _groups.size(),
		height_field.get_chain_count(), str(field_size), str(bake_size),
		_groups[0]["sprite"].scale.x, str(raster_rect.size)], 0)

#########################################################################################################
## ORDER PERSISTENCE
#########################################################################################################
# DD saves objects in sibling order and reloads them in that order (verified:
# Objects::Save iterates children, Objects::Load appends in array order), so the
# user's Bring to front / Send to back arrangement persists natively — but the
# ghost prop itself is skipped by the save (no node_id), so ITS place among them
# must be remembered by the mod. Per layer, ModMapData holds the node_ids of the
# objects BEHIND the ghost (i.e. shadowed); on rebuild/reload the ghost is
# re-inserted right after the last of them still present.
#
# Core polls sync_order_store() (throttled) so the stored lists track the user's
# button presses without needing a hook into DD's SelectTool, and clear() syncs
# once more before tearing the ghosts down.

func _get_order_store() -> Dictionary:
	if not global.ModMapData.has(core.ORDER_KEY):
		global.ModMapData[core.ORDER_KEY] = {}
	return global.ModMapData[core.ORDER_KEY]

func _restore_prop_order(objects, prop, layer: float):
	var stored = _get_order_store().get(str(int(layer)), [])
	var target = 0
	if stored is Array and stored.size() > 0:
		var stored_set = {}
		for nid in stored:
			stored_set[str(nid)] = true
		var best = -1
		for i in range(objects.get_child_count()):
			var child = objects.get_child(i)
			if child == prop:
				continue
			var nid = core.get_node_id(child)
			if nid != null and stored_set.has(nid):
				if i > best:
					best = i
		target = best + 1
	objects.move_child(prop, target)
	outputlog("layer %d -> shadow z=%d, child %d of %d in Objects (%d object(s) behind it)" % [
		int(layer), int(layer), prop.get_index(), objects.get_child_count(),
		stored.size() if stored is Array else 0], 1)

# Record which objects currently sit behind each ghost. Cheap (a walk of the
# Objects children per group), called throttled from Core and once from clear().
func sync_order_store():
	var changed = 0
	for g in _groups:
		var prop = g.get("prop")
		if prop == null or not is_instance_valid(prop):
			continue
		var parent = prop.get_parent()
		if parent == null:
			continue
		var behind = []
		for i in range(prop.get_index()):
			var nid = core.get_node_id(parent.get_child(i))
			if nid != null:
				behind.append(nid)
		var key = str(int(g["layer"]))
		var store = _get_order_store()
		if not store.has(key) or not (store[key] is Array) or store[key] != behind:
			store[key] = behind
			changed += 1
	if changed > 0:
		outputlog("order store updated for %d layer(s)" % changed, 1)

# Re-enable rendering, then freeze again shortly after. Keeps the march off the
# per-frame path while still guaranteeing it has actually run.
const BAKE_SETTLE_SEC = 0.35

var _freeze_timer = null

func _thaw_bake():
	# raster -> blur H -> blur V -> bake are four chained render targets; all must
	# be live for the result to propagate.
	if height_field != null:
		height_field.thaw()
	for g in _groups:
		if g["bake_vp"] != null and is_instance_valid(g["bake_vp"]):
			g["bake_vp"].render_target_update_mode = Viewport.UPDATE_ALWAYS
	if _groups.size() == 0:
		return
	if _freeze_timer == null or not is_instance_valid(_freeze_timer):
		_freeze_timer = Timer.new()
		_freeze_timer.one_shot = true
		_freeze_timer.wait_time = BAKE_SETTLE_SEC
		_freeze_timer.connect("timeout", self, "_freeze_bake")
		global.Editor.add_child(_freeze_timer)
	_freeze_timer.stop()
	_freeze_timer.start()

func _freeze_bake():
	if height_field != null:
		height_field.freeze()
	for g in _groups:
		_log_strength_histogram(g)
	for g in _groups:
		if g["bake_vp"] != null and is_instance_valid(g["bake_vp"]):
			# DISABLED keeps the last rendered frame; it does not clear the target.
			g["bake_vp"].render_target_update_mode = Viewport.UPDATE_DISABLED
	outputlog("%d bake(s) frozen" % _groups.size(), 1)

# Read one group's baked shadow back and histogram its strength.
#
# Settles "changing the fade does nothing" objectively: a real gradient shows a
# spread across many buckets, whereas two spikes means the fade is not reaching
# the output at all. Reasoning about the shader math cannot distinguish those.
# Per group, because a group whose channel rasterised nothing shows up here as a
# flat 0.0 while its neighbours do not.
func _log_strength_histogram(g):
	var vp = g["bake_vp"]
	if vp == null or not is_instance_valid(vp):
		return
	var tex = vp.get_texture()
	if tex == null:
		return
	var img = tex.get_data()
	if img == null:
		outputlog("strength histogram: bake for layer %d not readable yet" % int(g["layer"]), 0)
		return

	var tag = "slot %d/layer %d" % [g["slot"], int(g["layer"])]

	img.lock()
	var w = img.get_width()
	var h = img.get_height()
	var buckets = []
	for _i in range(11):
		buckets.append(0)
	var samples = 0
	var shadowed = 0
	var amax = 0.0
	var step = max(1, int(min(w, h) / 128))
	var y = 0
	while y < h:
		var x = 0
		while x < w:
			var a = img.get_pixel(x, y).r
			buckets[int(clamp(round(a * 10.0), 0.0, 10.0))] += 1
			if a > 0.01:
				shadowed += 1
			if a > amax:
				amax = a
			samples += 1
			x += step
		y += step

	var parts = PoolStringArray()
	for i in range(11):
		if buckets[i] > 0:
			parts.append("%.1f:%.1f%%" % [i / 10.0, 100.0 * buckets[i] / max(1, samples)])
	outputlog("strength histogram %s (%d samples, %.1f%% shadowed, max %.2f): %s" % [
		tag, samples, 100.0 * shadowed / max(1, samples), amax, parts.join(" ")], 0)

	# Aggregate stats cannot show the SHAPE of a profile. Dump consecutive strengths
	# across the widest shadow run, so the transition reads directly: a ramp means
	# the fade works, a cliff means it does not.
	var best_y = -1
	var best_run = 0
	var scan_step = max(1, int(h / 60))
	var yy = 0
	while yy < h:
		var run = 0
		var longest = 0
		for xx in range(w):
			if img.get_pixel(xx, yy).r > 0.02:
				run += 1
				if run > longest:
					longest = run
			else:
				run = 0
		if longest > best_run:
			best_run = longest
			best_y = yy
		yy += scan_step

	if best_y >= 0 and best_run > 8:
		var start = -1
		var run2 = 0
		var bs = -1
		for xx in range(w):
			if img.get_pixel(xx, best_y).r > 0.02:
				if run2 == 0:
					start = xx
				run2 += 1
				if run2 == best_run:
					bs = start
			else:
				run2 = 0
		if bs >= 0:
			var vals = PoolStringArray()
			var n = int(min(24, best_run))
			for k in range(n):
				var xi = bs + int(float(k) * float(best_run - 1) / float(max(1, n - 1)))
				vals.append("%.2f" % img.get_pixel(xi, best_y).r)
			outputlog("profile across widest shadow %s (row %d, %d px wide): %s" % [
				tag, best_y, best_run, vals.join(" ")], 0)

	img.unlock()

#########################################################################################################
## EXPORT LAYERING
#########################################################################################################
# Export renders the same tree through the same canvas with the same z order as
# the editor: Exporter.Viewport IS the live editor viewport, and
# ExportImage_Native just pans Exporter.Camera and reads GetTexture().GetData().
# There is no per-container export compositor, so nothing has to be copied
# anywhere — the per-layer sprites export exactly as they appear on screen.
# (SoftShadows' FloorShapes copy dance appears to be cargo-culted.)

func prepare_for_export():
	# Deliberately a no-op. Any copy or reparent would change the z ordering that
	# the whole per-layer placement depends on.
	return

func end_export():
	for g in _groups:
		if g["sprite"] != null and is_instance_valid(g["sprite"]):
			g["sprite"].visible = true

#########################################################################################################
## UNIFORMS
#########################################################################################################
# Everything the sun controls feeds through here. No geometry is touched, which
# is why direction/height/strength are now instant instead of triggering a
# full rebuild the way the mesh version did.

func update_uniforms():
	if height_field == null or _groups.size() == 0:
		return
	var raster_rect = height_field.get_raster_rect()
	if raster_rect == null:
		return

	var tex_a = height_field.get_field_texture(0)
	if tex_a == null:
		return
	var tex_b = height_field.get_field_texture(1)
	var have_b = tex_b != null
	if not have_b:
		tex_b = tex_a

	var sun = sun_settings.get_sun()
	var tier_px = float(sun.get("tier_px", 256.0))
	var altitude = clamp(float(sun.get("altitude", 35.0)), 1.0, 89.0)
	var softness = clamp(float(sun.get("softness", 0.5)), 0.0, 1.0)

	# Toward the sun is the opposite of the direction shadows fall.
	var sun_dir = -sun_settings.get_shadow_direction()

	# Angular extent of the sun -> the soft band the horizon angle is compared
	# against. Clamped so the band stays inside a sane altitude range.
	var spread = SPREAD_MIN_DEG + softness * (SPREAD_MAX_DEG - SPREAD_MIN_DEG)
	var alt_lo = clamp(altitude - spread, 0.5, 89.5)
	var alt_hi = clamp(altitude + spread, alt_lo + 0.25, 89.75)
	var tan_lo = tan(deg2rad(alt_lo))
	var tan_hi = tan(deg2rad(alt_hi))

	# March far enough to cover the longest shadow the tallest stack can throw.
	var max_tiers = _max_stack_tiers()
	var max_dist = max_tiers * tier_px / max(0.01, tan(deg2rad(alt_lo)))
	var diag = raster_rect.size.length()
	max_dist = min(max_dist, diag)

	# Geometric march. The first step is a fixed fraction of a field texel so the
	# near field (where the shadow edge is decided) is sampled finely; each
	# subsequent step grows. Growth is solved so the total reaches max_dist inside
	# the step budget — at a low sun that budget would otherwise force a stride of
	# several texels and the march would skip over occluders entirely.
	var texel_px = 1.0 / max(0.0001, height_field.get_vp_scale())
	var base_stride = max(1.0, texel_px * TARGET_STRIDE_TEXELS)
	var steps = MAX_MARCH_STEPS
	var growth = _solve_growth(base_stride, max_dist, steps)
	# A uniform stride suffices when the distance is short; skip the growth.
	if base_stride * float(steps) >= max_dist:
		steps = int(clamp(ceil(max_dist / base_stride), MIN_MARCH_STEPS, MAX_MARCH_STEPS))
		growth = 1.0

	# Ignore sub-tier differences: the field is bilinearly filtered, so a hard
	# tier boundary becomes a ramp a texel wide, and without a bias every pixel
	# on that ramp reads as a tiny occluder and self-shadows.
	# Must exceed the height change across the blur ramp between tiers, or every
	# pixel sitting on a ramp registers a phantom near-field occluder and reads as
	# fully dark. Scales with the blend width for that reason.
	var blend = float(sun.get("level_blend", 2.0))
	var self_bias = clamp(0.10 + blend * 0.04, 0.10, 0.45)
	# Attribution ("which layer owns this occluder") is a per-channel test, so the
	# same absolute bias would be too coarse when two layers' ramps overlap and
	# split the rise between them. A third of the self bias keeps up to three
	# simultaneously-contributing layers detectable; below that the shader falls
	# back to "highest channel with any rise at all", so nothing is ever left
	# unowned and punching a hole in the shadow.
	var attr_bias = self_bias / 3.0

	var last = _groups.size() - 1
	for g in _groups:
		var m = g["material"]
		m.set_shader_param("sun_dir_px", sun_dir)
		m.set_shader_param("raster_size_px", raster_rect.size)
		m.set_shader_param("tier_px", tier_px)
		m.set_shader_param("height_divisor", height_field.HEIGHT_DIVISOR)
		m.set_shader_param("tan_lo", tan_lo)
		m.set_shader_param("tan_hi", tan_hi)
		m.set_shader_param("base_stride_px", base_stride)
		m.set_shader_param("stride_growth", growth)
		m.set_shader_param("steps", steps)
		m.set_shader_param("opacity", float(sun.get("opacity", 0.55)))
		m.set_shader_param("self_bias_tiers", self_bias)
		m.set_shader_param("attr_bias_tiers", attr_bias)
		# Lets the shader stop marching once no remaining step could reach above the
		# light ray for this pixel.
		m.set_shader_param("max_tiers", max_tiers)
		# Second field chain, carrying slots 3..5.
		m.set_shader_param("field_b", tex_b)
		m.set_shader_param("use_field_b", 1.0 if have_b else 0.0)
		# Which slot this pass owns, and whether anything sits above it. Both are
		# read by the march: `group_slot` picks the occluders this sprite may draw,
		# `has_above` tells the early exit that no higher layer can ever subtract
		# from us, which restores the cheap single-pass exit for the top layer.
		m.set_shader_param("group_slot", int(g["slot"]))
		m.set_shader_param("has_above", 0.0 if g["slot"] >= last else 1.0)

		# Per-layer art mask ("Art above shadow" paths), channel-packed like the
		# field. A chain with no flagged paths has no texture; bind the field and
		# switch the mask off so no sampler is left unbound.
		var mask_chain = int(g["slot"] / height_field.SLOTS_PER_CHAIN)
		var mask_tex = height_field.get_mask_texture(mask_chain)
		if mask_tex != null:
			mask_tex.flags = Texture.FLAG_FILTER
		m.set_shader_param("art_mask", mask_tex if mask_tex != null else tex_a)
		m.set_shader_param("use_art_mask", 1.0 if mask_tex != null else 0.0)
		m.set_shader_param("mask_channel", g["slot"] % height_field.SLOTS_PER_CHAIN)

		# Shadow blockers ("Stops outside shadows"): the march ends where a
		# sun-ray crosses one. Same texture for every pass, or the telescoping
		# subtraction would disagree between layers about what exists.
		var blocker_tex = height_field.get_blocker_texture()
		if blocker_tex != null:
			blocker_tex.flags = Texture.FLAG_FILTER
		m.set_shader_param("blocker_tex", blocker_tex if blocker_tex != null else tex_a)
		m.set_shader_param("use_blocker", 1.0 if blocker_tex != null else 0.0)

	# The projected portal quads depend on the sun (direction, altitude) and
	# opacity, so they are rebuilt with every uniform change — a handful of
	# small meshes, cheap next to the march.
	_rebuild_pattern_quads()

	# Re-run the bakes with the new parameters. Without this the visible sprites
	# keep showing the previous march.
	_thaw_bake()

	outputlog("uniforms (%d group(s)): sun_dir=%s alt=%.1f+-%.1f (tan %.3f..%.3f) max_dist=%.0fpx steps=%d base_stride=%.1fpx (%.1f texels) growth=%.4f tiers=%.1f opacity=%.2f self_bias=%.3f attr_bias=%.3f field_b=%s" % [
		_groups.size(), str(sun_dir), altitude, spread, tan_lo, tan_hi, max_dist, steps,
		base_stride, base_stride / max(0.001, texel_px), growth, max_tiers,
		float(sun.get("opacity", 0.55)), self_bias, attr_bias, str(have_b)], 1)

#########################################################################################################
## PORTAL BEAM / PATTERN PROJECTION
#########################################################################################################
# An open portal is a vertical BAND in the wall's face (sill `bottom` to lintel
# `top`, in ft), optionally shaped by a pattern. Its effect on the ground
# projects as skewed parallelograms along the shadow direction — computed here
# at bake time, so the march never has to know:
#
#   d(x ft) = (x/fps) * tier_px / tan(altitude)      distance a height maps to
#
#   0        .. d(bottom) : solid shadow  (wall below the sill)
#   d(bottom).. d(top)    : the pattern's shadow (nothing, for a plain opening)
#   d(top)   .. d(wall_h) : solid shadow  (wall above the lintel), faded at the
#                           tail to meet the march's penumbra without a seam
#
# The quads render additively into the wall's own layer bake, filling the gap
# the strip cut left. UV.y runs up the opening's face, so patterns are
# authored face-on and the projection skews/stretches them with the sun —
# long dramatic lattices at sunset, compressed at noon.

func _rebuild_pattern_quads():
	if _pattern_shader == null:
		return
	var sun = sun_settings.get_sun()
	var alt = clamp(float(sun.get("altitude", 35.0)), 1.0, 89.0)
	var tan_alt = tan(deg2rad(alt))
	var tier_px = float(sun.get("tier_px", 256.0))
	var fps = sun_settings.get_feet_per_square()
	var dirv = sun_settings.get_shadow_direction()
	var opacity = clamp(float(sun.get("opacity", 0.55)), 0.0, 1.0)
	var quads = 0

	for g in _groups:
		var root = g.get("quad_root")
		if root == null or not is_instance_valid(root):
			continue
		for child in root.get_children():
			child.queue_free()
		for caster in height_field.get_group_casters(g["slot"]):
			if caster == null or not is_instance_valid(caster):
				continue
			var cfg = path_tagging.get_config(caster)
			# Only strip walls have portal gaps to fill.
			if int(cfg.get("side", 0)) != 2:
				continue
			var wall_ft = float(cfg.get("height", 1.0)) * fps
			for portal in path_tagging.get_wall_portals(caster):
				if not path_tagging.is_portal_open(portal):
					continue
				var pcfg = path_tagging.get_portal_cfg(portal)
				var a = portal.get("Begin")
				var b = portal.get("End")
				if not (a is Vector2 and b is Vector2) or (b - a).length() < 1.0:
					continue
				var bottom_ft = clamp(float(pcfg.get("bottom", 0.0)), 0.0, wall_ft)
				var top_ft = clamp(float(pcfg.get("top", 8.0)), bottom_ft, wall_ft)
				var tile_ft = max(0.5, float(pcfg.get("tile", 2.5)))
				var pattern = int(clamp(pcfg.get("pattern", 0), 0, _pattern_textures.size() - 1))

				var d_bottom = (bottom_ft / fps) * tier_px / tan_alt
				var d_top = (top_ft / fps) * tier_px / tan_alt
				var d_wall = (wall_ft / fps) * tier_px / tan_alt
				var tile_px = (tile_ft / fps) * tier_px
				var span_tiles = (b - a).length() / tile_px

				# Wall below the sill.
				if d_bottom > 1.0:
					quads += _add_quad(root, a, b, dirv, 0.0, d_bottom,
						null, 0.0, 0.0, 0.0, opacity, 1.0, 1.0)
				# The opening itself, pattern-shaped.
				if pattern > 0 and d_top > d_bottom + 1.0:
					quads += _add_quad(root, a, b, dirv, d_bottom, d_top,
						_pattern_textures[pattern], span_tiles,
						bottom_ft / tile_ft, top_ft / tile_ft, opacity, 1.0, 1.0)
				# Wall above the lintel: solid, with a faded tail so it meets
				# the march's penumbra without a hard line.
				if d_wall > d_top + 1.0:
					var d_fade = d_top + (d_wall - d_top) * 0.8
					quads += _add_quad(root, a, b, dirv, d_top, d_fade,
						null, 0.0, 0.0, 0.0, opacity, 1.0, 1.0)
					quads += _add_quad(root, a, b, dirv, d_fade, d_wall,
						null, 0.0, 0.0, 0.0, opacity, 1.0, 0.0)
	if quads > 0:
		outputlog("portal projection: %d quad(s) built" % quads, 1)

# One projected parallelogram: span a..b extruded along `dirv` from d0 to d1.
# UVs tile the pattern across the span (u) and up the opening face (v);
# alpha0/alpha1 are the vertex alphas at the near/far edge (tail fading).
func _add_quad(root, a: Vector2, b: Vector2, dirv: Vector2, d0: float, d1: float,
	tex, u_tiles: float, v0: float, v1: float, strength: float,
	alpha0: float, alpha1: float) -> int:

	var p0 = a + dirv * d0
	var p1 = b + dirv * d0
	var p2 = b + dirv * d1
	var p3 = a + dirv * d1

	var verts = PoolVector2Array([p0, p1, p2, p0, p2, p3])
	var uvs = PoolVector2Array([
		Vector2(0, v0), Vector2(u_tiles, v0), Vector2(u_tiles, v1),
		Vector2(0, v0), Vector2(u_tiles, v1), Vector2(0, v1)])
	var c0 = Color(1, 1, 1, alpha0)
	var c1 = Color(1, 1, 1, alpha1)
	var colors = PoolColorArray([c0, c0, c1, c0, c1, c1])

	var arrays = []
	arrays.resize(ArrayMesh.ARRAY_MAX)
	arrays[ArrayMesh.ARRAY_VERTEX] = verts
	arrays[ArrayMesh.ARRAY_TEX_UV] = uvs
	arrays[ArrayMesh.ARRAY_COLOR] = colors
	var mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mi = MeshInstance2D.new()
	mi.mesh = mesh
	if tex != null:
		mi.texture = tex
	var mat = ShaderMaterial.new()
	mat.shader = _pattern_shader
	mat.set_shader_param("strength", strength)
	mi.material = mat
	root.add_child(mi)
	return 1

# Growth factor g such that a geometric series of `steps` terms starting at
# `base` sums to at least `target`:  base * (g^n - 1) / (g - 1) >= target.
# Solved by bisection — no closed form, and it runs once per settings change.
func _solve_growth(base: float, target: float, steps: int) -> float:
	if base * float(steps) >= target:
		return 1.0
	var lo = 1.0
	var hi = 1.5
	for _i in range(40):
		var mid = (lo + hi) * 0.5
		var total = base * (pow(mid, steps) - 1.0) / (mid - 1.0)
		if total < target:
			lo = mid
		else:
			hi = mid
	return (lo + hi) * 0.5

# Bound on the tallest stacked elevation. Two sources:
#
#   * analytic — every caster's drop summed. Always safe, but on a nested map it
#     overshoots badly (40 contours of 1 tier each never stack 40 deep).
#   * measured — the maximum actually read back out of the raster, cached in
#     HeightField across rebuilds.
#
# The bound feeds `head_room`, which is what lets the march stop early. That
# mattered little when one pass could always exit on its own running maximum, but
# a per-layer pass has to keep marching until it can rule out a HIGHER layer's
# occluder, so a 5x-too-large bound now costs 5x the steps. Take the smaller of
# the two, with a tier of margin because the readback is a sparse grid sample.
func _max_stack_tiers() -> float:
	var analytic = 0.0
	for path in path_tagging.get_caster_nodes():
		analytic += float(path_tagging.get_config(path).get("height", 1.0))
	analytic = max(1.0, analytic)
	var measured = height_field.get_max_height_tiers()
	if measured >= 1.0:
		return max(1.0, min(analytic, measured + 1.0))
	return analytic
