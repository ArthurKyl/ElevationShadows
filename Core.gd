#########################################################################################################
##
## ELEVATION SHADOWS — CORE
##
#########################################################################################################
# Pipeline:
#   PathTagging   — which contours are casters, their uphill side and drop height
#   HeightField   — rasterises those contours into an elevation texture (plus the
#                   per-layer "Art above shadow" mask)
#   ShadowRenderer— one ghost Prop per caster layer inside Level.Objects, each
#                   showing that layer's baked sun march
# (ShadowBuilder, the abandoned per-path mesh extruder, was deleted 2026-08-07.)
#
# Design decisions this implements (see the design discussion, not re-derived here):
#   - Casters are DD path nodes tagged via a toggle, with a manual high-side
#     (Side A / Side B / Both) button. No automatic inference of "which way is down".
#   - One global sun, synced with DD's native RoofTool.SunDirection so cliff
#     shadows and roof shadows agree instead of pointing different ways.
#   - Config lives in Global.ModMapData, keyed by node_id, so it saves with the map.

var script_class = "tool"

const ENABLE_LOGGING = true
var logging_level = 1

# ModMapData keys. SUN_KEY holds one dict for the whole map; CASTER_KEY is
# keyed by node_id; ORDER_KEY holds, per caster layer, the node_ids of the
# objects the user sent BEHIND that layer's shadow (Send to back), so the ghost
# prop can be re-inserted at the same spot on rebuild/reload.
const SUN_KEY = "ElevationShadowsSun"
const CASTER_KEY = "ElevationShadowsCasters"
const ORDER_KEY = "ElevationShadowsOrder"
# Per-portal override for "does sunlight pass here", keyed by node_id.
# DD's own Portal.Closed defaults to false and (at least in this DD build)
# has no reachable UI, so the mod exposes its own toggle; the DD flag is only
# the fallback default.
const PORTAL_KEY = "ElevationShadowsPortals"

var SunSettingsScript
var PathTaggingScript
var HeightFieldScript
var ShadowRendererScript
var sun_settings = null
var path_tagging = null
var height_field = null
var shadow_renderer = null

#########################################################################################################
## LOGGING
#########################################################################################################

func outputlog(msg, level = 0):
	if ENABLE_LOGGING and level <= logging_level:
		printraw("(%d) <ElevationShadows>: " % OS.get_ticks_msec())
		print(msg)

#########################################################################################################
## SHARED UTILITIES
#########################################################################################################

# Returns a tool panel's content VBoxContainer. Uses the documented .Align
# property first so it survives mods that re-parent Align into an HBox for a
# resize handle (e.g. ResizeLeftPanel). Mirrors SoftShadows/Core.gd.
func get_align_vbox(tool_panel):
	if tool_panel == null:
		return null
	if tool_panel.get("Align") != null:
		return tool_panel.Align
	for i in range(tool_panel.get_child_count()):
		var child = tool_panel.get_child(i)
		if child is VBoxContainer:
			return child
	for i in range(tool_panel.get_child_count()):
		var child = tool_panel.get_child(i)
		if child is HBoxContainer:
			for j in range(child.get_child_count()):
				var sub = child.get_child(j)
				if sub is VBoxContainer:
					return sub
	return null

# Nodes that can cast elevation shadows. A DD path is a Line2D exposing FadeIn.
# A DD WALL exposes Joint and a C# Points property — it is NOT a Line2D itself:
# it is a Node2D that builds child Line2D segments (which is how portals cut
# gaps into it). Portals expose WallID and are excluded.
func is_path_node(node) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	if node.get("WallID") != null:
		return false
	if node.get("FadeIn") != null:
		return true
	return node.get("Joint") != null and node.get("Points") != null

# A door/window on a wall. Portals are the only things exposing WallID.
func is_portal_node(node) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	return node.get("WallID") != null

# Reorder a path's points into a canonical direction.
#
# A path's normal comes from its direction of travel, so drawing the same ridge
# bottom-to-top instead of top-to-bottom flips which side "Side A" refers to.
# That makes the Side flag meaningless in absolute terms and forces the user to
# work it out per contour.
#
# Canonicalising by geometry instead of draw order fixes it: every path is made
# to run left-to-right (top-to-bottom when near-vertical), so Side A is the same
# geometric side for all of them. For a stack of roughly parallel contours that
# means one Side setting is correct for the whole stack.
#
# The comparison is on relative coordinates only, so local and world space reach
# the same decision.
func orient_points(pts):
	var count = pts.size()
	if count < 2:
		return pts
	var a = pts[0]
	var b = pts[count - 1]
	var reverse = false
	if abs(b.x - a.x) > 1.0:
		reverse = b.x < a.x
	else:
		reverse = b.y < a.y
	if not reverse:
		return pts
	var out = PoolVector2Array()
	for i in range(count - 1, -1, -1):
		out.append(pts[i])
	return out

func get_node_id(node):
	if node == null or not is_instance_valid(node):
		return null
	if not node.has_meta("node_id"):
		return null
	return str(node.get_meta("node_id"))

#########################################################################################################
## ENTRY POINT
#########################################################################################################

func start() -> void:
	outputlog("Elevation Shadows loading (height field + per-pixel sun march)", 0)

	if Engine.has_signal("_lib_register_mod"):
		Engine.emit_signal("_lib_register_mod", self)

	SunSettingsScript = ResourceLoader.load(Global.Root + "SunSettings.gd", "GDScript", true)
	if SunSettingsScript == null:
		outputlog("FATAL: SunSettings.gd failed to load", 0)
		return
	sun_settings = SunSettingsScript.new()
	sun_settings.global = Global
	sun_settings.core = self
	sun_settings.initialise()

	PathTaggingScript = ResourceLoader.load(Global.Root + "PathTagging.gd", "GDScript", true)
	if PathTaggingScript == null:
		outputlog("FATAL: PathTagging.gd failed to load", 0)
		return
	path_tagging = PathTaggingScript.new()
	path_tagging.global = Global
	path_tagging.core = self
	path_tagging.sun_settings = sun_settings
	path_tagging.initialise()

	HeightFieldScript = ResourceLoader.load(Global.Root + "HeightField.gd", "GDScript", true)
	if HeightFieldScript == null:
		outputlog("FATAL: HeightField.gd failed to load", 0)
		return
	height_field = HeightFieldScript.new()
	height_field.global = Global
	height_field.core = self
	height_field.sun_settings = sun_settings
	height_field.path_tagging = path_tagging
	height_field.initialise()

	ShadowRendererScript = ResourceLoader.load(Global.Root + "ShadowRenderer.gd", "GDScript", true)
	if ShadowRendererScript == null:
		outputlog("FATAL: ShadowRenderer.gd failed to load", 0)
		return
	shadow_renderer = ShadowRendererScript.new()
	shadow_renderer.global = Global
	shadow_renderer.core = self
	shadow_renderer.sun_settings = sun_settings
	shadow_renderer.path_tagging = path_tagging
	shadow_renderer.height_field = height_field
	shadow_renderer.initialise()

	# Cross-wire so config changes can trigger a rebuild.
	sun_settings.height_field = height_field
	path_tagging.height_field = height_field
	sun_settings.shadow_renderer = shadow_renderer
	path_tagging.shadow_renderer = shadow_renderer
	# Sun height changes refresh the per-path "casts X ft" readout.
	sun_settings.path_tagging = path_tagging

	# Map data is not populated at start(); defer the load-time read.
	var timer = Timer.new()
	timer.wait_time = 0.6
	timer.one_shot = true
	timer.connect("timeout", self, "_on_map_load_timer")
	Global.Editor.add_child(timer)
	timer.start()

	outputlog("Elevation Shadows loaded.", 0)

func _on_map_load_timer():
	if sun_settings != null:
		sun_settings.apply_saved_state()
	if path_tagging != null:
		path_tagging.report_saved_state()
	_hook_export_dialog()
	# Only draw on load if we are in Live mode; Off and Export only stay clear.
	if get_mode() == MODE_LIVE:
		build_all()
	else:
		outputlog("mode=%d on load — nothing built" % get_mode(), 0)

#########################################################################################################
## REBUILD SCHEDULER
#########################################################################################################
# Dragging a slider fires value_changed every tick. Rebuilding everything on each
# one made the sliders lag — the mesh pass is O(N^2) per contour and the field
# pass re-rasterises, runs Clipper, and re-reads the render target. Coalesce
# instead: mark what is dirty, and do the work once the user pauses.

const REBUILD_DEBOUNCE = 0.12

# Master modes.
const MODE_OFF = 0
const MODE_EXPORT_ONLY = 1
const MODE_LIVE = 2

func get_mode() -> int:
	if sun_settings == null:
		return MODE_LIVE
	return sun_settings.get_mode()

# Remove everything from the scene without forgetting any configuration.
func teardown_all():
	if shadow_renderer != null:
		shadow_renderer.clear()
	if height_field != null:
		height_field.disable()
	outputlog("torn down (mode=%d)" % get_mode(), 0)

func build_all():
	# Drop the sprites BEFORE re-rasterising. Their bake viewports sample the height
	# field's render targets, so tearing the field down first would leave live
	# viewports holding ViewportTextures whose targets have been freed.
	if shadow_renderer != null:
		shadow_renderer.clear()
	# Field next — every shadow sprite is textured from it, and the renderer reads
	# the layer grouping the field just computed.
	if height_field != null:
		height_field.rebuild()
	if shadow_renderer != null:
		shadow_renderer.rebuild()

# HeightField reads the finished raster back a frame after each rebuild and
# measures the tallest stack actually present. That number bounds the march's
# early exit, and the analytic bound it replaces (every caster's drop summed) can
# be several times too large — which now costs real time, because a per-layer pass
# has to keep marching until it can rule out a higher layer's occluder. Called
# only when the measurement moved enough to matter, so this is one extra bake per
# rebuild at most.
func on_height_field_measured():
	if shadow_renderer == null:
		return
	if get_mode() == MODE_OFF:
		return
	shadow_renderer.update_uniforms()

var _rebuild_timer = null
var _want_mesh = false
var _want_field = false

func request_rebuild(mesh: bool, field: bool):
	# Off and Export only both mean "do not compute anything now". Export only
	# builds on demand from the export hook below.
	if get_mode() != MODE_LIVE:
		return
	_want_mesh = _want_mesh or mesh
	_want_field = _want_field or field
	if not _want_mesh and not _want_field:
		return
	if _rebuild_timer == null:
		_rebuild_timer = Timer.new()
		_rebuild_timer.one_shot = true
		_rebuild_timer.wait_time = REBUILD_DEBOUNCE
		_rebuild_timer.connect("timeout", self, "_on_rebuild_timeout")
		Global.Editor.add_child(_rebuild_timer)
	# Restart the countdown so a continuous drag only rebuilds once, at the end.
	_rebuild_timer.stop()
	_rebuild_timer.start()

func _on_rebuild_timeout():
	# A field change invalidates the texture the sprite samples, so it implies a
	# renderer rebuild. A sun change only needs new uniforms.
	if _want_field and height_field != null:
		build_all()
	elif _want_mesh and shadow_renderer != null:
		shadow_renderer.update_uniforms()
	_want_mesh = false
	_want_field = false

#########################################################################################################
## EXPORT HOOK
#########################################################################################################
# Makes "Export only" real: build the shadows while the export window is open,
# then remove them again when it closes. DD's PNG and Universal VTT output both
# come from this one window, so a shadow present here lands in both.
#
# Shadow meshes are children of their path nodes, inside DD's normal hierarchy,
# so the export pipeline renders them without the FloorShapes copy trick that
# SoftShadows needs for its detached "behind layer" container.

var _export_dialog = null
var _built_for_export = false

func _hook_export_dialog():
	if _export_dialog != null and is_instance_valid(_export_dialog):
		return
	if Global.Editor == null or not ("Windows" in Global.Editor):
		return
	if not (Global.Editor.Windows is Dictionary):
		return
	var dialog = Global.Editor.Windows.get("Export")
	if dialog == null:
		outputlog("Export window not found — 'Export only' mode will not inject", 0)
		return
	_export_dialog = dialog
	if not dialog.is_connected("about_to_show", self, "_on_export_about_to_show"):
		dialog.connect("about_to_show", self, "_on_export_about_to_show")
	if not dialog.is_connected("popup_hide", self, "_on_export_popup_hide"):
		dialog.connect("popup_hide", self, "_on_export_popup_hide")
	outputlog("Export window hooked", 0)

func _on_export_about_to_show():
	if get_mode() == MODE_OFF:
		return
	# Re-bake at export resolution (double the render-target caps) in BOTH modes:
	# a 100 px/square export is ~2.2x the editor bake, and upscaling softens
	# the shadow's contact edge against crisp art. The dialog stays open for
	# seconds before the user clicks Export, which is ample settle time.
	_set_export_boost(true)
	if get_mode() == MODE_EXPORT_ONLY:
		_built_for_export = true
	outputlog("export opening — rebaking shadows at export resolution", 0)
	build_all()
	if shadow_renderer != null:
		shadow_renderer.prepare_for_export()

func _on_export_popup_hide():
	if shadow_renderer != null:
		shadow_renderer.end_export()
	_set_export_boost(false)
	if _built_for_export:
		outputlog("export closed — removing shadows again", 0)
		teardown_all()
		_built_for_export = false
	elif get_mode() == MODE_LIVE:
		# Back to editor resolution; keeping the boosted targets alive would
		# hold double the VRAM for no visible gain at editor zoom.
		build_all()

func _set_export_boost(on: bool):
	if height_field != null:
		height_field.export_boost = on
	if shadow_renderer != null:
		shadow_renderer.export_boost = on

#########################################################################################################
## PROCESS LOOP
#########################################################################################################

var _store_last_selection = []

# The ghost props' place among the user's objects changes through DD's own
# Bring to front / Send to back, which the mod has no hook into. Poll instead:
# a walk of the Objects children twice a second is negligible next to a frame.
# The same tick watches for a LEVEL SWITCH — casters are filtered to the
# current level and the ghosts live in the current level's Objects, so shadows
# must be rebuilt when the user changes level, and DD offers no signal for it.
const ORDER_SYNC_INTERVAL = 0.5
var _order_sync_accum = 0.0
var _last_level = null

func update(_delta):
	if Global.Editor.ActiveToolName == "SelectTool":
		if _has_selection_changed():
			if path_tagging != null:
				path_tagging.on_selection_changed()

	_order_sync_accum += _delta
	if _order_sync_accum >= ORDER_SYNC_INTERVAL:
		_order_sync_accum = 0.0
		_check_level_switch()
		_check_caster_changes()
		if shadow_renderer != null:
			shadow_renderer.sync_order_store()

var _last_caster_fp = 0

# DD has no delete/edit signal for paths or walls, so caster geometry changes
# are detected by fingerprint on the same tick. A deleted caster otherwise
# leaves its shadow baked into the field forever (and the sun sliders keep
# re-baking from that stale field, which looks extra haunted).
func _check_caster_changes():
	if path_tagging == null or get_mode() != MODE_LIVE:
		return
	var fp = path_tagging.caster_fingerprint()
	if fp == _last_caster_fp:
		return
	var first = _last_caster_fp == 0
	_last_caster_fp = fp
	if first:
		return
	outputlog("caster set/geometry changed — rebuilding field", 1)
	request_rebuild(false, true)

func _check_level_switch():
	var level = Global.World.GetCurrentLevel()
	if level == _last_level:
		return
	var first_sight = _last_level == null
	_last_level = level
	# First observation is just startup, and the load timer already builds then.
	if first_sight or level == null:
		return
	if get_mode() != MODE_LIVE:
		return
	outputlog("level switched to '%s' — rebuilding shadows there" % str(level.name), 0)
	build_all()

func _has_selection_changed() -> bool:
	var current = Global.Editor.Tools["SelectTool"].Selected
	if current.size() != _store_last_selection.size():
		_store_last_selection = current.duplicate()
		return true
	for i in range(current.size()):
		if current[i] != _store_last_selection[i]:
			_store_last_selection = current.duplicate()
			return true
	return false
