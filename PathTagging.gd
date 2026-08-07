#########################################################################################################
##
## PATH TAGGING — mark contour paths as elevation shadow casters
##
#########################################################################################################
# Adds a "Cast Elevation Shadow" toggle to PathTool (applies to newly drawn
# paths) and to SelectTool (edits the selected path). Per-path config is stored
# in Global.ModMapData keyed by node_id, so it saves with the map.
#
# Per-path settings kept deliberately small:
#   side   — which side of the contour is uphill (A / B), or "Wall (both)":
#            a free-standing wall where only the path's strip is raised and
#            both sides stay low. Manual by design: inferring the side from
#            geometry is unreliable for contours that run off the canvas AND
#            ones fully contained in it, and a button costs almost nothing.
#   height — the drop in elevation units. Drives shadow length together with the
#            global sun altitude. 1.0 = one tier.
#   art_above / mask_inset — whether and how tightly the path's artwork hides
#            its own layer's shadow edge (see CASTER_DEFAULTS below).

var global
var core = null
var sun_settings = null
var height_field = null
var shadow_renderer = null

# Config keys that change the shape of the elevation field (or the art mask
# rasterised alongside it), so the field pass has to be re-run rather than just
# the shader uniforms updated.
const FIELD_KEYS = ["enabled", "side", "height", "art_above", "mask_inset"]

const CASTER_DEFAULTS = {
	"enabled": false,
	"side": 0,        # 0 = Side A, 1 = Side B, 2 = Wall (free-standing, both sides low)
	# Elevation drop in TIERS (grid squares of height) — the internal unit the
	# field and the march work in, and what old maps already store. The UI
	# converts to/from FEET via feet_per_square (5 ft/square by default), so a
	# stored 1.0 displays as 5 ft. Shadow length is physically accurate from
	# height and sun altitude: length = height / tan(altitude), in any unit.
	"height": 1.0,
	# Whether this path's ARTWORK draws above its own layer's shadow (the shadow
	# slides under it, so the texture's alpha edge is the visible boundary).
	# null = "not set": casters default to true (a cliff's bumpy edge must hide
	# the shadow's leading edge), everything else to false (a road on the same
	# layer should receive the shadow). Buttons can't do this one — Bring to
	# front/Send to back reorder within the Pathways container, and the shadow
	# node lives in Objects, so path-vs-shadow order is fixed by tree order and
	# only the mask can exempt the art. See get_art_above().
	"art_above": null,
	# World px to erode the art mask's alpha edge by, across the strip. The mask
	# raster is ~6 px per texel and bilinear, so its edge smears a couple of px
	# past the art's visible edge on some assets — a small positive inset tucks
	# the shadow the rest of the way under. Negative dilates (shadow peeks out).
	# Implemented as UV-space alpha erosion in MaskChannel.shader. NOT a width
	# change on the copy — TILE mode derives its tiling count from the width, so
	# a width change rescales the art along the path and the whole visible
	# shadow boundary slides lengthwise.
	# Default 5: the user tuned this on their real cliff assets (2026-08-07) —
	# it covers the mask's bilinear smear plus typical soft texture fringes.
	"mask_inset": 5.0,
	# REMOVED: "padding" (ShadowBuilder-era shadow start offset). Old stored
	# values merge into the config dict harmlessly; nothing reads them.
}

const SIDE_NAMES = ["Side A", "Side B", "Wall (both)"]

var pt_ui = {}      # PathTool controls (defaults for new paths)
var st_ui = {}      # SelectTool controls (edits current selection)
var new_path_defaults = {}

var _syncing = false
var _current_path = null

func outputlog(msg, level = 0):
	if core != null:
		core.outputlog("[Paths] " + str(msg), level)

#########################################################################################################
## STATE
#########################################################################################################

func _get_store() -> Dictionary:
	if not global.ModMapData.has(core.CASTER_KEY):
		global.ModMapData[core.CASTER_KEY] = {}
	return global.ModMapData[core.CASTER_KEY]

func get_config(node) -> Dictionary:
	var nid = core.get_node_id(node)
	if nid == null:
		return CASTER_DEFAULTS.duplicate()
	var store = _get_store()
	if store.has(nid):
		var cfg = CASTER_DEFAULTS.duplicate()
		for key in store[nid].keys():
			cfg[key] = store[nid][key]
		return cfg
	return CASTER_DEFAULTS.duplicate()

func set_config_value(node, key: String, value):
	var nid = core.get_node_id(node)
	if nid == null:
		outputlog("Cannot store config: node has no node_id", 0)
		return
	var store = _get_store()
	if not store.has(nid):
		store[nid] = CASTER_DEFAULTS.duplicate()
	store[nid][key] = value
	outputlog("path %s: %s = %s" % [nid, key, str(value)], 1)
	# Every per-path setting changes the elevation field, so the field (and the
	# sprite textured from it) must be rebuilt. Debounced through Core so
	# dragging Drop height doesn't re-rasterise on every tick.
	# Mode gating lives in request_rebuild.
	if core != null and key in FIELD_KEYS:
		core.request_rebuild(false, true)

func get_caster_nodes() -> Array:
	"""Every path tagged as an enabled caster, ON THE CURRENT LEVEL and visible.
	Fed to the height field, so anything included here casts a shadow."""
	var result = []
	var store = _get_store()
	var level = global.World.GetCurrentLevel()
	var off_level = 0
	var hidden = 0

	for nid in store.keys():
		if not store[nid].get("enabled", false):
			continue
		if not global.World.HasNodeID(nid):
			continue
		var node = global.World.GetNodeByID(nid)
		if node == null or not is_instance_valid(node):
			continue
		# Tags survive a level clone by node_id, so a map can carry enabled
		# casters on levels that are not being edited — e.g. the original
		# `ground-shadows` level after cloning to `ground-elev`. Without this
		# filter those cast shadows from cliffs that are not even on screen.
		if level != null and not _is_descendant_of(node, level):
			off_level += 1
			continue
		# A hidden path should not cast either.
		if node.has_method("is_visible_in_tree") and not node.is_visible_in_tree():
			hidden += 1
			continue
		result.append(node)

	if off_level > 0 or hidden > 0:
		outputlog("casters: %d used, %d skipped (other level), %d skipped (hidden)" % [
			result.size(), off_level, hidden], 0)
	return result

# DD's "User Layer" as a z value (Layer 3 = 300).
# DD's layer IS z_index: PathTool::SetLayer does `ActivePath.ZIndex = metadata`,
# and Pathway exposes no Layer/UserLayer/SortLayer field at all (its fields are
# Smoothness/EditPoints/FadeIn/FadeOut/Grow/Shrink/BlockLight/widths/occluder).
# The old multi-name probe only ever worked via its z_index fallback.
#
# READ ONLY. Nothing in this mod ever assigns z_index/ZIndex to a caster, an
# object or a DD container — the user's layering is deliberate (objects that
# overhang a cliff edge are put on the cliff's own layer on purpose) and changing
# it would break their map. The mod sets z only on the sprites it creates itself.
#
# HeightField groups casters by this value; each group gets one ghost prop in
# Level.Objects at z = layer. There is deliberately no get_min/get_max_caster_layer:
# both returned 0.0 for a momentarily empty caster set, and the single sprite
# derived from them then parked at z=1, underneath every path, wall and object.
# With per-layer groups an empty caster set produces zero groups and zero sprites,
# so there is no z left to get wrong.
func get_caster_layer(node) -> float:
	return float(node.z_index)

# Effective "Art above shadow" for a path: the stored value if the user set it,
# otherwise the caster flag (casters protect their own art by default,
# non-casters receive the shadow by default).
func get_art_above(node) -> bool:
	var cfg = get_config(node)
	var explicit = cfg.get("art_above", null)
	if explicit != null:
		return bool(explicit)
	return bool(cfg.get("enabled", false))

# Paths whose artwork must sit above their own layer's shadow, grouped by layer
# (int z_index) for the mask rasteriser. Only paths with a config entry can
# qualify (the effective default for untouched paths is false), so iterating
# the store — with the same level/visibility filters as get_caster_nodes —
# covers everything.
func get_art_above_paths() -> Dictionary:
	var out = {}
	var store = _get_store()
	var level = global.World.GetCurrentLevel()
	for nid in store.keys():
		if not global.World.HasNodeID(nid):
			continue
		var node = global.World.GetNodeByID(nid)
		if node == null or not is_instance_valid(node):
			continue
		if level != null and not _is_descendant_of(node, level):
			continue
		if node.has_method("is_visible_in_tree") and not node.is_visible_in_tree():
			continue
		if not get_art_above(node):
			continue
		var key = int(round(get_caster_layer(node)))
		if not out.has(key):
			out[key] = []
		out[key].append(node)
	return out

func _is_descendant_of(node, ancestor) -> bool:
	var walker = node
	var guard = 0
	while walker != null and guard < 32:
		if walker == ancestor:
			return true
		walker = walker.get_parent()
		guard += 1
	return false

#########################################################################################################
## INIT
#########################################################################################################

func initialise():
	new_path_defaults = CASTER_DEFAULTS.duplicate()
	_build_path_tool_ui()
	_build_select_tool_ui()
	outputlog("initialised", 0)

func _build_path_tool_ui():
	var panel = global.Editor.Toolset.GetToolPanel("PathTool")
	if panel == null:
		outputlog("PathTool panel not found", 0)
		return
	var align = core.get_align_vbox(panel)
	if align == null:
		outputlog("PathTool Align VBox not found", 0)
		return

	var container = VBoxContainer.new()
	container.name = "ElevationShadowsPathTool"

	var sep = HSeparator.new()
	container.add_child(sep)

	var row = HBoxContainer.new()
	var label = Label.new()
	label.text = "Elevation Shadow"
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var toggle = CheckButton.new()
	toggle.pressed = false
	toggle.connect("toggled", self, "_on_pt_enabled_toggled")
	row.add_child(toggle)
	container.add_child(row)
	pt_ui["enabled"] = toggle

	var side_btn = Button.new()
	side_btn.text = SIDE_NAMES[0]
	side_btn.hint_tooltip = ("Which side of the contour is uphill.\n" +
		"Wall (both): a free-standing wall - only the path itself is raised,\n" +
		"both sides stay low. A closed circle of wall shades its inside\n" +
		"on the sun-facing arc, like a crater rim.")
	side_btn.connect("pressed", self, "_on_pt_side_pressed")
	container.add_child(side_btn)
	pt_ui["side"] = side_btn

	align.add_child(container)
	outputlog("PathTool UI added", 0)

func _build_select_tool_ui():
	var panel = global.Editor.Toolset.GetToolPanel("SelectTool")
	if panel == null:
		outputlog("SelectTool panel not found", 0)
		return
	var align = core.get_align_vbox(panel)
	if align == null:
		outputlog("SelectTool Align VBox not found", 0)
		return

	var container = VBoxContainer.new()
	container.name = "ElevationShadowsSelectTool"
	container.visible = false

	var sep = HSeparator.new()
	container.add_child(sep)

	var row = HBoxContainer.new()
	var label = Label.new()
	label.text = "Elevation Shadow"
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var toggle = CheckButton.new()
	toggle.connect("toggled", self, "_on_st_enabled_toggled")
	row.add_child(toggle)
	container.add_child(row)
	st_ui["enabled"] = toggle

	var side_btn = Button.new()
	side_btn.text = SIDE_NAMES[0]
	side_btn.hint_tooltip = ("Which side of the contour is uphill.\n" +
		"Wall (both): a free-standing wall - only the path itself is raised,\n" +
		"both sides stay low. A closed circle of wall shades its inside\n" +
		"on the sun-facing arc, like a crater rim.")
	side_btn.connect("pressed", self, "_on_st_side_pressed")
	container.add_child(side_btn)
	st_ui["side"] = side_btn

	var height_label = Label.new()
	height_label.text = "Drop height (ft)"
	height_label.hint_tooltip = ("How far the ground drops on the shadow side, in feet\n" +
		"(one grid square = 5 ft). Shadow length is physically\n" +
		"accurate for this height at the current sun angle.")
	container.add_child(height_label)
	var height_row = HBoxContainer.new()
	var height_slider = HSlider.new()
	height_slider.min_value = 1.0
	height_slider.max_value = 120.0
	height_slider.step = 1.0
	height_slider.value = 5.0
	height_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	height_slider.connect("value_changed", self, "_on_st_height_changed")
	height_row.add_child(height_slider)
	# The spinbox deliberately accepts DOUBLE the slider's range: type past
	# 120 ft for extreme cliffs instead of adding an "extreme heights" toggle.
	var height_spin = SpinBox.new()
	height_spin.min_value = 1.0
	height_spin.max_value = 240.0
	height_spin.step = 1.0
	height_spin.value = 5.0
	height_spin.hint_tooltip = "Type values up to 240 ft (the slider stops at 120)."
	height_spin.connect("value_changed", self, "_on_st_height_spin_changed")
	height_row.add_child(height_spin)
	container.add_child(height_row)
	st_ui["height_slider"] = height_slider
	st_ui["height_spin"] = height_spin

	# Live realism readout: what this wall's shadow measures at the current sun.
	var length_note = Label.new()
	length_note.autowrap = true
	length_note.modulate = Color(1, 1, 1, 0.6)
	container.add_child(length_note)
	st_ui["length_note"] = length_note

	var art_row = HBoxContainer.new()
	var art_label = Label.new()
	art_label.text = "Art above shadow"
	art_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	art_label.hint_tooltip = ("This path's artwork draws over its own layer's shadow,\n" +
		"so the texture's real edge hides where the shadow starts.\n" +
		"On by default for shadow casters. Higher layers' shadows\nstill darken it.")
	art_row.add_child(art_label)
	var art_toggle = CheckButton.new()
	art_toggle.connect("toggled", self, "_on_st_art_above_toggled")
	art_row.add_child(art_toggle)
	container.add_child(art_row)
	st_ui["art_above"] = art_toggle

	var inset_row = HBoxContainer.new()
	var inset_label = Label.new()
	inset_label.text = "Shadow inset"
	inset_label.rect_min_size = Vector2(104, 0)
	inset_label.hint_tooltip = ("Fine-tunes where the shadow disappears under this path's art,\n" +
		"in pixels. Positive tucks it further under (hides a sliver of\n" +
		"gap on assets with soft edges); negative lets it peek out.")
	inset_row.add_child(inset_label)
	var inset_slider = HSlider.new()
	inset_slider.min_value = -64.0
	inset_slider.max_value = 64.0
	inset_slider.step = 0.5
	inset_slider.value = 5.0
	inset_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inset_slider.connect("value_changed", self, "_on_st_inset_changed")
	inset_row.add_child(inset_slider)
	var inset_spin = SpinBox.new()
	inset_spin.min_value = -64.0
	inset_spin.max_value = 64.0
	inset_spin.step = 0.5
	inset_spin.value = 5.0
	inset_spin.connect("value_changed", self, "_on_st_inset_spin_changed")
	inset_row.add_child(inset_spin)
	container.add_child(inset_row)
	st_ui["inset_slider"] = inset_slider
	st_ui["inset_spin"] = inset_spin

	align.add_child(container)
	st_ui["container"] = container
	outputlog("SelectTool UI added", 0)

#########################################################################################################
## PATHTOOL CALLBACKS (defaults for newly drawn paths)
#########################################################################################################

func _on_pt_enabled_toggled(pressed):
	new_path_defaults["enabled"] = pressed
	outputlog("new-path default enabled = %s" % str(pressed), 0)

func _on_pt_side_pressed():
	var next_side = (new_path_defaults.get("side", 0) + 1) % 3
	new_path_defaults["side"] = next_side
	pt_ui["side"].text = SIDE_NAMES[next_side]
	outputlog("new-path default side = %s" % SIDE_NAMES[next_side], 0)

#########################################################################################################
## SELECTTOOL CALLBACKS (edit current selection)
#########################################################################################################

func on_selection_changed():
	var selected = global.Editor.Tools["SelectTool"].Selected
	var path = null
	for node in selected:
		if core.is_path_node(node):
			path = node
			break

	_current_path = path
	if not st_ui.has("container"):
		return

	if path == null:
		st_ui["container"].visible = false
		return

	st_ui["container"].visible = true
	var cfg = get_config(path)
	var h_ft = float(cfg.get("height", 1.0)) * _feet_per_square()
	_syncing = true
	st_ui["enabled"].pressed = cfg.get("enabled", false)
	st_ui["side"].text = SIDE_NAMES[int(cfg.get("side", 0))]
	st_ui["height_slider"].value = h_ft
	st_ui["height_spin"].value = h_ft
	if st_ui.has("art_above"):
		st_ui["art_above"].pressed = get_art_above(path)
	if st_ui.has("inset_slider"):
		st_ui["inset_slider"].value = cfg.get("mask_inset", 5.0)
		st_ui["inset_spin"].value = cfg.get("mask_inset", 5.0)
	_syncing = false
	update_length_readout()

func _on_st_enabled_toggled(pressed):
	if _syncing or _current_path == null:
		return
	set_config_value(_current_path, "enabled", pressed)

func _on_st_side_pressed():
	if _current_path == null:
		return
	var cfg = get_config(_current_path)
	var next_side = (int(cfg.get("side", 0)) + 1) % 3
	set_config_value(_current_path, "side", next_side)
	st_ui["side"].text = SIDE_NAMES[next_side]

func _feet_per_square() -> float:
	if sun_settings != null and sun_settings.has_method("get_feet_per_square"):
		return sun_settings.get_feet_per_square()
	return 5.0

# UI values are FEET; storage is tiers (grid squares). Convert at the boundary.
func _on_st_height_changed(value):
	if _syncing or _current_path == null:
		return
	set_config_value(_current_path, "height", value / _feet_per_square())
	_syncing = true
	st_ui["height_spin"].value = value
	_syncing = false
	update_length_readout()

func _on_st_height_spin_changed(value):
	if _syncing or _current_path == null:
		return
	set_config_value(_current_path, "height", value / _feet_per_square())
	_syncing = true
	# The slider caps at half the spinbox's range; assigning past its max just
	# pins it there while the stored value keeps the typed number.
	st_ui["height_slider"].value = value
	_syncing = false
	update_length_readout()

# "This wall is 20 ft up, so its shadow is 34 ft" — the physically accurate
# number, straight from height / tan(sun altitude). Refreshed on selection,
# height edits, and sun-altitude changes (SunSettings calls in).
func update_length_readout():
	if not st_ui.has("length_note"):
		return
	if _current_path == null or not st_ui["container"].visible:
		return
	var fps = _feet_per_square()
	var h_ft = float(get_config(_current_path).get("height", 1.0)) * fps
	var len_ft = h_ft * sun_settings.get_length_ratio()
	st_ui["length_note"].text = "Casts %.0f ft of shadow (%.1f squares)" % [
		len_ft, len_ft / fps]

func _on_st_art_above_toggled(pressed):
	if _syncing or _current_path == null:
		return
	set_config_value(_current_path, "art_above", pressed)

func _on_st_inset_changed(value):
	if _syncing or _current_path == null:
		return
	set_config_value(_current_path, "mask_inset", value)
	_syncing = true
	st_ui["inset_spin"].value = value
	_syncing = false

func _on_st_inset_spin_changed(value):
	if _syncing or _current_path == null:
		return
	set_config_value(_current_path, "mask_inset", value)
	_syncing = true
	st_ui["inset_slider"].value = value
	_syncing = false

#########################################################################################################
## LOAD
#########################################################################################################

func report_saved_state():
	var store = _get_store()
	var total = store.size()
	var enabled = 0
	var alive = 0
	for nid in store.keys():
		if store[nid].get("enabled", false):
			enabled += 1
		if global.World.HasNodeID(nid):
			alive += 1
	outputlog("Loaded caster state: %d entries (%d enabled, %d still present in map)" % [
		total, enabled, alive], 0)
