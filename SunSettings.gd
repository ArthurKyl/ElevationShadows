#########################################################################################################
##
## GLOBAL SUN — Effects-category tool panel
##
#########################################################################################################
# One sun for the whole map: azimuth (compass direction the light comes FROM)
# and altitude (height above the horizon). Altitude drives shadow length via
# length = drop_height / tan(altitude), so a low sun throws long shadows.
#
# DD's RoofTool already exposes a native SunDirection control that its own roof
# shading uses. We read it at startup and offer to follow it, so cliff shadows
# and roof shadows can't disagree. Its units are logged on first contact because
# they are not documented anywhere we can see.

var global
var core = null
var height_field = null
var shadow_renderer = null
var path_tagging = null   # for refreshing the per-path shadow-length readout

const SUN_DEFAULTS = {
	# Master mode: 0 = Off, 1 = Export only, 2 = Live. See Core.MODE_*.
	#   Off         — nothing rendered, nothing recalculated. For heavy editing.
	#   Export only — hidden while editing, generated on export so the output
	#                 image still has shadows without paying for them in the editor.
	#   Live        — visible in the editor.
	"mode": 2,
	"azimuth": 135.0,        # degrees; direction the light comes FROM (0 = north/up, clockwise)
	"altitude": 35.0,        # degrees above horizon; low = long shadows
	"follow_roof_sun": true, # mirror DD's native RoofTool.SunDirection
	"opacity": 0.55,         # global shadow strength
	"softness": 0.5,         # how fast the shadow blurs with distance (0 = stays crisp)
	# World px of height per elevation tier. Taken from DD's tile size at load, so
	# one tier = one grid square. Not exposed: it scales shadow length, which is
	# what Sun height already does, so two controls for it only confuses things.
	"tier_px": 256.0,
	# Feet per grid square, for the TTRPG-facing labels only. Heights are stored
	# and marched in grid squares (tiers); this converts them for display, so
	# changing it re-labels the world without moving a single shadow. 5 ft is
	# the D&D convention. No UI — edit the map's saved value for exotic grids.
	"feet_per_square": 5.0,
	# REMOVED KEYS (old saved values in a map's store are simply ignored —
	# apply_saved_state only reads keys present in these defaults):
	#   group_z_offset            — the shadow node must sit at EXACTLY z = layer
	#                               or Bring to front / Send to back dies;
	#   occlude_forward, min_clip_px, edge_extend_px
	#                             — ShadowBuilder-only (deleted mesh extruder);
	#   art_mask_enabled          — the old GLOBAL art mask; per-path "Art above
	#                               shadow" is its per-layer successor;
	#   edge_inset_mult           — pulled the elevation step back from the
	#                               centreline; produced the smooth offset curve
	#                               the user rejected. The step stays ON the
	#                               centreline and the mask hides the edge;
	#   step_falloff ("Length fade"), depth_falloff
	#                             — artistic fades a real shadow does not have.
	#                               Removed 2026-08-07 with the user's sign-off:
	#                               Diffusion's physically-correct penumbra covers
	#                               the intent, the user ran them at 0, and the
	#                               fade's ramp was normalised by worst-case reach
	#                               so short shadows just darkened uniformly.
	# How gradually one elevation level blends into the next, in height-field
	# texels (~6 world px each). The field is stepped by whole tiers, so without
	# blending the shadow's length and its depth fade both jump abruptly at every
	# contour. Raising this turns those steps into gradients. Distinct from
	# Diffusion, which only softens the shadow's outer edge.
	# Not exposed: an anti-aliasing width for the elevation field, not an artistic
	# choice. Too low and contour staircases cast streaks; too high and phantom
	# occluders appear on the blur ramps.
	"level_blend": 3.0,
	"debug_height_field": false,
}

# Which settings invalidate what.
#   UNIFORM_KEYS — the march reads these as shader parameters, so changing them
#                  is a parameter write. No geometry, no rasterising, instant.
#   FIELD_KEYS   — change the elevation field itself, so it must be re-rasterised
#                  and the sprite rebuilt.
# Anything in neither list changes no output and must not trigger a rebuild
# (debug_height_field only shows/hides the overlay; follow_roof_sun only affects
# whether azimuth tracks DD's slider).
const MESH_KEYS = ["azimuth", "altitude", "opacity", "softness", "tier_px"]
const FIELD_KEYS = ["tier_px", "level_blend"]

var sun = {}
var ui = {}

var _roof_sun_control = null
var _syncing = false
var _pushing_to_roof = false
var _mode_buttons = []

func outputlog(msg, level = 0):
	if core != null:
		core.outputlog("[Sun] " + str(msg), level)

#########################################################################################################
## STATE
#########################################################################################################

func _get_store() -> Dictionary:
	if not global.ModMapData.has(core.SUN_KEY):
		global.ModMapData[core.SUN_KEY] = {}
	# Seed any missing keys with their defaults. Without this, a setting the user
	# never touched is simply absent from the map, so it silently reverts to the
	# factory value on reload rather than persisting what they saw.
	var store = global.ModMapData[core.SUN_KEY]
	for key in SUN_DEFAULTS.keys():
		if not store.has(key):
			store[key] = sun.get(key, SUN_DEFAULTS[key])
	return store

func get_sun() -> Dictionary:
	return sun

# Unit vector pointing along the direction shadows are cast (i.e. away from the
# sun), in DD's screen space where +y is down.
func get_shadow_direction() -> Vector2:
	var a = deg2rad(sun.get("azimuth", 135.0))
	# azimuth 0 = light from the top of the screen, so shadows fall downward.
	return Vector2(-sin(a), cos(a)).normalized()

# Horizontal shadow length in world px for a drop of `drop` height units.
func get_shadow_length(drop: float, px_per_height_unit: float) -> float:
	var alt = clamp(sun.get("altitude", 35.0), 1.0, 89.0)
	return drop * px_per_height_unit / tan(deg2rad(alt))

func get_feet_per_square() -> float:
	return max(0.1, float(sun.get("feet_per_square", 5.0)))

# Physically accurate shadow-length-to-wall-height ratio at the current sun:
# cot(altitude). This is the number the panel note and the per-path readout
# both derive from, so "realistically, that is how long the shadow should be"
# is answerable directly off the UI.
func get_length_ratio() -> float:
	var alt = clamp(float(sun.get("altitude", 35.0)), 1.0, 89.0)
	return 1.0 / tan(deg2rad(alt))

#########################################################################################################
## INIT
#########################################################################################################

func initialise():
	sun = SUN_DEFAULTS.duplicate()

	if global.Editor == null or global.Editor.Toolset == null:
		outputlog("Toolset not ready — sun tool not created", 0)
		return

	var icon = global.Root + "icons/elevation_sun.png"
	var panel = global.Editor.Toolset.CreateModTool(
		self, "Effects", "ElevationShadowsTool", "Elevation Shadows", icon)
	if panel == null:
		outputlog("CreateModTool returned null — tool not created", 0)
		return

	var container = core.get_align_vbox(panel)
	if container == null:
		container = panel
		outputlog("Align VBox not found; building into the panel root", 0)

	_build_ui(container)
	_probe_roof_sun()
	outputlog("Effects tool created", 0)

#########################################################################################################
## UI
#########################################################################################################

func _build_ui(parent):
	# Master mode goes first — it is the control you reach for most often.
	var mode_label = Label.new()
	mode_label.text = "Elevation Shadows"
	parent.add_child(mode_label)

	var mode_row = HBoxContainer.new()
	var mode_names = ["Off", "Export only", "Live"]
	var mode_tips = [
		"Nothing rendered, nothing recalculated.\nUse while making major map edits.",
		"Hidden while editing, but generated when you export,\nso the exported image still has shadows.",
		"Visible in the editor.",
	]
	_mode_buttons = []
	for i in range(3):
		var btn = Button.new()
		btn.text = mode_names[i]
		btn.hint_tooltip = mode_tips[i]
		btn.toggle_mode = true
		btn.pressed = (int(sun.get("mode", 2)) == i)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.connect("pressed", self, "_on_mode_pressed", [i])
		mode_row.add_child(btn)
		_mode_buttons.append(btn)
	parent.add_child(mode_row)

	parent.add_child(HSeparator.new())

	var title = Label.new()
	title.text = "Global Sun"
	parent.add_child(title)

	ui["azimuth"] = _add_slider_row(parent, "Direction", "azimuth", 0.0, 359.0, 1.0,
		"Compass direction the light comes FROM.\n0 = from the top of the map.")
	ui["altitude"] = _add_slider_row(parent, "Sun height", "altitude", 1.0, 89.0, 1.0,
		"How high the sun sits.\nLow = long shadows. This is the main length control.")

	# The realism readout: shadow length is physically cot(altitude) x wall
	# height, so this one line tells the mapmaker exactly what lowering the sun
	# buys them. Updated by _update_ratio_note().
	var ratio_note = Label.new()
	ratio_note.autowrap = true
	ratio_note.modulate = Color(1, 1, 1, 0.6)
	parent.add_child(ratio_note)
	ui["ratio_note"] = ratio_note
	_update_ratio_note()

	var sep = HSeparator.new()
	parent.add_child(sep)

	var shadow_label = Label.new()
	shadow_label.text = "Shadow"
	parent.add_child(shadow_label)

	ui["opacity"] = _add_slider_row(parent, "Strength", "opacity", 0.0, 1.0, 0.01,
		"How dark a shadow is at its darkest, right at the cliff.")
	ui["softness"] = _add_slider_row(parent, "Diffusion", "softness", 0.0, 1.0, 0.01,
		"How blurry the shadow's outer edge is.\nThe blur widens with distance from the cliff, like real penumbra.")
	# No "Length fade" (a real shadow stays equally dark to its end; Diffusion's
	# penumbra is the physical version of the look) and no "Layer offset" (the
	# shadow node must sit at EXACTLY z = its layer for Bring to front / Send to
	# back to work against it) — see the REMOVED KEYS note in SUN_DEFAULTS.

	var sep2 = HSeparator.new()
	parent.add_child(sep2)

	var dbg = CheckButton.new()
	dbg.text = "Show elevation field"
	dbg.hint_tooltip = "Overlay the raw height field.\nBrighter = higher ground; the colour is the caster's layer\n(red/green/blue = 1st/2nd/3rd layer found)."
	dbg.pressed = sun.get("debug_height_field", false)
	dbg.connect("toggled", self, "_on_debug_height_toggled")
	parent.add_child(dbg)
	ui["debug_height_field"] = dbg

	var follow = CheckButton.new()
	follow.text = "Follow DD roof sun"
	follow.pressed = sun.get("follow_roof_sun", true)
	follow.connect("toggled", self, "_on_follow_toggled")
	parent.add_child(follow)
	ui["follow_roof_sun"] = follow

	var note = Label.new()
	note.text = "Per-pixel sun march over the\nelevation field."
	note.autowrap = true
	note.modulate = Color(1, 1, 1, 0.5)
	parent.add_child(note)

# Label + slider + spinbox, two-way bound, writing into `sun[key]`.
func _add_slider_row(parent, label_text: String, key: String,
	min_val: float, max_val: float, step_val: float, tip: String = "") -> Dictionary:

	# Label lives INSIDE the row, not on a line above it. Stacking a label above
	# every slider made the panel ~24 controls tall (a real overflow risk in DD's
	# fixed-height tool panel) and left it ambiguous which slider a label named.
	var row = HBoxContainer.new()

	var label = Label.new()
	label.text = label_text
	label.rect_min_size = Vector2(104, 0)
	label.clip_text = true
	if tip != "":
		label.hint_tooltip = tip
	row.add_child(label)

	var slider = HSlider.new()
	slider.min_value = min_val
	slider.max_value = max_val
	slider.step = step_val
	slider.value = sun.get(key, min_val)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if tip != "":
		slider.hint_tooltip = tip
	var err_s = slider.connect("value_changed", self, "_on_slider_changed", [key])
	row.add_child(slider)

	var spin = SpinBox.new()
	spin.min_value = min_val
	spin.max_value = max_val
	spin.step = step_val
	spin.value = sun.get(key, min_val)
	var err_p = spin.connect("value_changed", self, "_on_spin_changed", [key])
	row.add_child(spin)

	parent.add_child(row)
	# Report connect() results and the resolved range. Several sliders were found
	# to never deliver value_changed at all, so verify the wiring at build time
	# rather than inferring it from behaviour.
	outputlog("row '%s' key=%s range=[%s..%s] step=%s init=%s connect(slider)=%d connect(spin)=%d" % [
		label_text, key, str(min_val), str(max_val), str(step_val),
		str(slider.value), err_s, err_p], 0)
	return {"slider": slider, "spin": spin}

func _on_slider_changed(value, key):
	# Unconditional entry log: distinguishes "signal never arrived" from
	# "signal arrived but was suppressed".
	outputlog("slider event key=%s value=%s syncing=%s" % [key, str(value), str(_syncing)], 0)
	if _syncing:
		return
	_set_value(key, value)
	_syncing = true
	if ui.has(key):
		ui[key]["spin"].value = value
	_syncing = false

func _on_spin_changed(value, key):
	outputlog("spin event key=%s value=%s syncing=%s" % [key, str(value), str(_syncing)], 0)
	if _syncing:
		return
	_set_value(key, value)
	_syncing = true
	if ui.has(key):
		ui[key]["slider"].value = value
	_syncing = false

func _on_mode_pressed(mode_index):
	_set_value("mode", mode_index)
	_set_mode_buttons(mode_index)
	if core == null:
		return
	if mode_index == 2:
		core.request_rebuild(true, true)
	else:
		# Off and Export only both mean "nothing on screen right now". Export
		# only rebuilds on demand from Core's export hook.
		core.teardown_all()

func _set_mode_buttons(active: int):
	for i in range(_mode_buttons.size()):
		_mode_buttons[i].pressed = (i == active)

func get_mode() -> int:
	return int(sun.get("mode", 2))

func _on_debug_height_toggled(pressed):
	_set_value("debug_height_field", pressed)
	if height_field != null:
		height_field.set_debug_visible(pressed)

func _on_follow_toggled(pressed):
	_set_value("follow_roof_sun", pressed)
	if pressed:
		_pull_roof_sun()

func _update_ratio_note():
	if not ui.has("ratio_note"):
		return
	var alt = clamp(float(sun.get("altitude", 35.0)), 1.0, 89.0)
	var fps = get_feet_per_square()
	ui["ratio_note"].text = "Sun at %.0f°: shadows reach %.1fx wall height\n(a %.0f ft wall casts %.0f ft)" % [
		alt, get_length_ratio(), 4.0 * fps, 4.0 * fps * get_length_ratio()]

func _set_value(key: String, value):
	sun[key] = value
	_get_store()[key] = value
	outputlog("%s = %s" % [key, str(value)], 1)
	if key == "azimuth":
		_push_azimuth_to_roof_sun()
	if key == "altitude":
		_update_ratio_note()
		# The per-path "casts X ft" readout depends on the sun too.
		if path_tagging != null:
			path_tagging.update_length_readout()
	# Only rebuild what this particular setting actually invalidates, and let
	# Core coalesce it. Rebuilding everything on every tick — including for
	# settings that change nothing — is what made the sliders lag.
	if core != null:
		core.request_rebuild(key in MESH_KEYS, key in FIELD_KEYS)

func _sync_ui_from_state():
	_syncing = true
	for key in ui.keys():
		if not (ui[key] is Dictionary):
			continue
		if not sun.has(key):
			continue
		ui[key]["slider"].value = sun[key]
		ui[key]["spin"].value = sun[key]
	for flag_key in ["follow_roof_sun", "debug_height_field"]:
		if ui.has(flag_key) and ui[flag_key] is CheckButton:
			ui[flag_key].pressed = sun.get(flag_key, true)
	if _mode_buttons.size() == 3:
		_set_mode_buttons(int(sun.get("mode", 2)))
	_syncing = false
	_update_ratio_note()

#########################################################################################################
## DD NATIVE ROOF SUN
#########################################################################################################

# RoofTool exposes a SunDirection control that DD's roof shading uses.
# SoftShadows hooks it (DropShadowRoofs: "Hooked RoofTool.SunDirection.value_changed"),
# so it is reachable. Units/range are undocumented — log them so we can map ours onto it.
func _probe_roof_sun():
	# SunDirection is a property on the *tool object*, not a node in its panel.
	# Searching the panel tree for it never finds anything (learned the hard way).
	var roof_tool = global.Editor.Tools.get("RoofTool")
	if roof_tool == null:
		outputlog("RoofTool not in Editor.Tools — cannot follow native sun", 0)
		return
	var found = roof_tool.get("SunDirection")
	if found == null:
		outputlog("RoofTool.SunDirection missing — cannot follow native sun", 0)
		return
	_roof_sun_control = found
	outputlog("RoofTool.SunDirection found: class=%s value=%s min=%s max=%s step=%s" % [
		found.get_class(),
		str(found.get("value")),
		str(found.get("min_value")),
		str(found.get("max_value")),
		str(found.get("step")),
	], 0)
	if found.has_signal("value_changed"):
		found.connect("value_changed", self, "_on_roof_sun_changed")
		outputlog("Connected to RoofTool.SunDirection.value_changed", 0)
	# Deliberately do NOT pull here: ModMapData isn't loaded yet at init, so
	# pulling now would write the roof value into the store and the map's saved
	# azimuth would be lost when apply_saved_state() reads it back. The pull
	# happens at the end of apply_saved_state() instead.

func _on_roof_sun_changed(value):
	if _pushing_to_roof:
		return  # our own write echoing back
	if not sun.get("follow_roof_sun", true):
		return
	outputlog("Native roof sun changed -> %s" % str(value), 1)
	_pull_roof_sun()

#########################################################################################################
## AZIMUTH <-> DD SunDirection CONVERSION
#########################################################################################################
# Two different conventions, so be explicit about both:
#
#   ours  — `azimuth`, 0..359 degrees, compass style: the direction the light
#           comes FROM, 0 = top of screen, increasing clockwise.
#           from_vector = (sin a, -cos a)
#
#   DD's  — `RoofTool.SunDirection`, -180..180 degrees, atan2(y, x) in screen
#           space (+y down), pointing AT the sun. DropShadowRoofs treats
#           shadow = sun + 180.
#           from_vector = (cos s, sin s)
#
# Equating the two gives a = 90 - s, and therefore s = 90 - a.

func _dd_sun_to_azimuth(s: float) -> float:
	var a = 90.0 - s
	while a < 0.0:
		a += 360.0
	while a >= 360.0:
		a -= 360.0
	return a

func _azimuth_to_dd_sun(a: float) -> float:
	var s = 90.0 - a
	while s > 180.0:
		s -= 360.0
	while s < -180.0:
		s += 360.0
	return s

func _pull_roof_sun():
	if _roof_sun_control == null or not is_instance_valid(_roof_sun_control):
		return
	var raw = _roof_sun_control.get("value")
	if raw == null:
		return
	var az = _dd_sun_to_azimuth(float(raw))
	outputlog("Pulled native sun %s deg -> azimuth %s deg" % [str(raw), str(az)], 1)
	_set_value("azimuth", az)
	_sync_ui_from_state()

# Push our azimuth back into DD's control so roof shading agrees with the
# cliffs. Guarded so the resulting value_changed doesn't bounce back at us.
func _push_azimuth_to_roof_sun():
	if _roof_sun_control == null or not is_instance_valid(_roof_sun_control):
		return
	if not sun.get("follow_roof_sun", true):
		return
	_pushing_to_roof = true
	_roof_sun_control.value = _azimuth_to_dd_sun(float(sun.get("azimuth", 135.0)))
	_pushing_to_roof = false

#########################################################################################################
## DD TOOL CALLBACKS
#########################################################################################################
# CreateModTool() was handed `self`, so DD will call these on us. They must
# exist even as no-ops — this is a settings panel with no canvas behaviour.
# (Same shape as SoftShadows/SoftShadowsTool.gd.)

func update(_delta):
	pass

func on_tool_enable(_tool_id):
	pass

func on_tool_disable(_tool_id):
	pass

func on_content_input(_event):
	pass

#########################################################################################################
## LOAD
#########################################################################################################

func apply_saved_state():
	var store = _get_store()
	var restored = 0
	for key in SUN_DEFAULTS.keys():
		if store.has(key):
			sun[key] = store[key]
			restored += 1
	# One tier = one grid square, read from DD rather than guessed.
	if global.World != null:
		var inst = global.World.get("Instance")
		if inst != null and inst.get("TileSize") != null:
			var ts = float(inst.get("TileSize"))
			if ts > 8.0:
				sun["tier_px"] = ts
				_get_store()["tier_px"] = ts
				outputlog("tier_px = %.0f (from DD TileSize)" % ts, 0)

	_sync_ui_from_state()
	outputlog("Loaded sun state: %d/%d keys restored from map. azimuth=%s altitude=%s" % [
		restored, SUN_DEFAULTS.size(), str(sun.get("azimuth")), str(sun.get("altitude"))], 0)
	outputlog("Derived shadow_dir=%s  length_for_1_unit_drop@256px=%.1fpx" % [
		str(get_shadow_direction()), get_shadow_length(1.0, 256.0)], 0)

	# Now that saved state is in place, reconcile with DD's native sun.
	if sun.get("follow_roof_sun", true) and _roof_sun_control != null:
		var native = _roof_sun_control.get("value")
		outputlog("Native SunDirection=%s (maps to azimuth %s); saved azimuth=%s" % [
			str(native), str(_dd_sun_to_azimuth(float(native))), str(sun.get("azimuth"))], 0)
		# Our azimuth wins on load — the map's saved value is the user's intent —
		# and we push it into DD so roof shading matches the cliffs.
		_push_azimuth_to_roof_sun()
