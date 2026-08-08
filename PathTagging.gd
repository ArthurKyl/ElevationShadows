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
const FIELD_KEYS = ["enabled", "side", "height", "art_above", "mask_inset", "blocks"]

const CASTER_DEFAULTS = {
	"enabled": false,
	# For PATHS (Line2D): 0 = Side A, 1 = Side B (terrain contour — which side
	# is uphill), 2 = Wall (free-standing strip, both sides low).
	# For WALL nodes (Joint != null): the wall is ALWAYS a strip (contour fills
	# are meaningless for walls — a wall on side 0/1 used to silently fill half
	# the map as terrain, which is exactly the confusion this replaces), and
	# the value picks the CAST side instead: 0 = shadow on Side A only,
	# 1 = Side B only, 2 = both sides. One-sided walls keep the un-cast side
	# completely clean (a closed house wall on Side A shades the outside world
	# while its interior stays fully lit, so DD's indoor lights work). Which
	# side is "A" is arbitrary per wall — flip the button if it's wrong.
	"side": 0,
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
	# "Stops outside shadows": the path/wall's strip becomes a shadow BLOCKER —
	# the march stops when a sun-ray crosses it, so shadows cast by anything
	# BEYOND it (mountains, cliffs) never reach the near side. Deliberately
	# non-physical: a mountain's shadow really would cover a house's interior
	# (it covers the roof), but battlemaps show the floor plan, and the floor
	# plan should be lit. Independent of "enabled" — a wall can block without
	# casting, cast without blocking, or both. Open portals pass through the
	# blocker too (same strip, same gap cutting), so an open door lets an
	# outside cliff's shadow spill into the room, which is the cool part.
	"blocks": false,
	# REMOVED: "padding" (ShadowBuilder-era shadow start offset). Old stored
	# values merge into the config dict harmlessly; nothing reads them.
}

const SIDE_NAMES = ["Side A", "Side B", "Wall (both)"]
# Wall nodes reuse the same stored `side` value but read it as the CAST side
# (see CASTER_DEFAULTS), so the button shows wall-flavoured labels for them.
const WALL_SIDE_NAMES = ["Side A", "Side B", "Both sides"]

const PATH_SIDE_TOOLTIP = ("Which side of the contour is uphill.\n" +
	"Wall (both): a free-standing wall - only the path itself is raised,\n" +
	"both sides stay low. A closed circle of wall shades its inside\n" +
	"on the sun-facing arc, like a crater rim.")
const WALL_SIDE_TOOLTIP = ("Which side of the wall the shadow falls on - flip if it's\n" +
	"the wrong one. Side A / Side B cast on ONE side only: on a\n" +
	"closed wall, Side A shades the outside and keeps the interior\n" +
	"fully lit (so indoor lights work), Side B shades the inside\n" +
	"(courtyard/crater). Both sides: the classic free-standing wall.")

# A DD wall node (WallTool): Node2D with a C# Joint property. Paths are Line2D.
func is_wall_node(node) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	return node.get("Joint") != null

# Button label for the side value, per node kind.
func side_label(node, side: int) -> String:
	if is_wall_node(node):
		return WALL_SIDE_NAMES[side % 3]
	return SIDE_NAMES[side % 3]

# Per-portal light-opening settings (portal store, keyed by node_id, alongside
# "open"). All in FEET. The opening is a vertical band in the wall's face from
# `bottom` to `top`; light passes through it (shaped by `pattern`), while the
# wall below the sill and above the lintel still shades — which is what makes
# beams end at a realistic distance instead of streaking across the map.
const PORTAL_DEFAULTS = {
	"pattern": 0,     # index into PATTERN_NAMES, or PATTERN_CUSTOM; 0 = plain opening
	"top": 8.0,       # ft — lintel height (door tops out here)
	"bottom": 0.0,    # ft — sill height (0 for doors, raise for windows)
	"tile": 2.5,      # ft — pattern tile size (one bar/pane/plus per tile)
	# Image path for the "Custom texture" pattern. A plain STRING (like the sun
	# tint's hex string) — DD's map serialization is only trusted with simple
	# types. "" = none; an unloadable path falls back to a plain opening at
	# rebuild time (ShadowRenderer warns in the log).
	"pattern_file": "",
	# Draw this portal's pattern as shadow on ground its wall does not shade
	# (a house set to shade only its exterior still gets window patterns on the
	# interior floor). Independent of "open" — a closed door projects.
	"project": false,
}

const PATTERN_NAMES = ["None (open)", "Bars", "Window panes", "Diamond lattice", "Plus holes", "Checker"]
# One past the generated patterns: the "Custom texture..." OptionButton entry.
# Arthur's contract for custom images: any texel with non-0% opacity blocks
# light at 100% (enforced by ShadowRenderer's load-time threshold).
const PATTERN_CUSTOM = 6

var pt_ui = {}      # PathTool controls (defaults for new paths)
var st_ui = {}      # SelectTool controls (edits current selection)
var new_path_defaults = {}
# What newly placed portals get stamped with (PortalTool panel toggle).
# Session-sticky, like DD's own tool options.
var new_portal_open_default = true
var new_portal_project_default = false

var _syncing = false
var _current_path = null
var _current_portal = null
# Custom-pattern image picker (lazy singleton) and the portal it was opened for.
var _pattern_file_dialog = null
var _pattern_file_portal = null

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

func _get_portal_store() -> Dictionary:
	if not global.ModMapData.has(core.PORTAL_KEY):
		global.ModMapData[core.PORTAL_KEY] = {}
	return global.ModMapData[core.PORTAL_KEY]

# Every path/wall flagged "Stops outside shadows", on the current level and
# visible. Independent of the caster flag.
func get_blocker_nodes() -> Array:
	var result = []
	var store = _get_store()
	var level = global.World.GetCurrentLevel()
	for nid in store.keys():
		if not store[nid].get("blocks", false):
			continue
		if not global.World.HasNodeID(nid):
			continue
		var node = global.World.GetNodeByID(nid)
		if node == null or not is_instance_valid(node):
			continue
		if level != null and not _is_descendant_of(node, level):
			continue
		if node.has_method("is_visible_in_tree") and not node.is_visible_in_tree():
			continue
		result.append(node)
	return result

# A wall's portals. NOT via wall.get("Portals"): that C# property is a
# System.Collections.Generic.List<Portal>, which Godot's bridge cannot marshal
# to a Variant — get() silently returns null (the bug: no doorway gap was ever
# cut, while the toggles "worked" because they only write the store). Portals
# are nodes in the level's Portals container referencing their wall by WallID
# (int32); resolving WallID through DD's own GetNodeByID and comparing node
# identity sidesteps every id-format question.
# Wall-attached portals are CHILDREN OF THE WALL NODE: Wall::AddPortal
# instances the portal scene and AddChilds it to the wall (verified in the
# assembly). The level's Portals container — where two earlier versions of
# this lookup searched, silently finding nothing — holds only FREESTANDING
# portals.
func get_wall_portals(wall, verbose: bool = false) -> Array:
	var out = []
	var report = PoolStringArray()
	for child in wall.get_children():
		if child == null or not is_instance_valid(child):
			continue
		if child.get("WallID") == null:
			continue
		out.append(child)
		if verbose and report.size() < 8:
			report.append("open=%s" % str(is_portal_open(child)))
	if verbose:
		outputlog("portal scan for wall %s: %d portal(s) among %d wall children | %s" % [
			str(core.get_node_id(wall)), out.size(), wall.get_child_count(),
			report.join(" ; ")], 0)
	return out

# Portals not attached to any LIVING wall: freestanding ones, and ones whose
# WallID points at a deleted/redrawn wall. These get matched to walls by
# PROXIMITY in the strip cutter — DD only writes a WallID when the portal
# snapped onto the wall at placement, and a door dropped onto the art without
# snapping should still make a gap.
func get_unattached_portals() -> Array:
	var out = []
	var level = global.World.GetCurrentLevel()
	if level == null:
		return out
	var container = level.get("Portals")
	if container == null:
		return out
	for child in container.get_children():
		if child == null or not is_instance_valid(child):
			continue
		var wid = child.get("WallID")
		if wid == null:
			continue
		if global.World.HasNodeID(wid) and global.World.GetNodeByID(wid) != null:
			continue
		out.append(child)
	return out

func get_portal_cfg(portal) -> Dictionary:
	var cfg = PORTAL_DEFAULTS.duplicate()
	var nid = core.get_node_id(portal)
	if nid != null:
		var store = _get_portal_store()
		if store.has(nid) and store[nid] is Dictionary:
			for k in store[nid].keys():
				cfg[k] = store[nid][k]
	return cfg

func set_portal_value(portal, key: String, value):
	var nid = core.get_node_id(portal)
	if nid == null:
		outputlog("Cannot store portal setting: no node_id", 0)
		return
	var store = _get_portal_store()
	if not (store.has(nid) and store[nid] is Dictionary):
		store[nid] = {}
	store[nid][key] = value
	outputlog("portal %s: %s = %s" % [nid, key, str(value)], 1)
	# Pattern/heights only reshape the projected quads, which are rebuilt in
	# update_uniforms — no field re-raster needed ("open" is separate and does
	# need the field, its handler asks for that itself).
	if core != null:
		core.request_rebuild(true, false)

# Does sunlight pass through this portal? The mod's own per-portal toggle wins;
# otherwise DD's Portal.Closed decides (its default is false = open — and this
# DD build exposes no UI for it, which is why the mod has its own toggle).
# Both the wall-strip gap cutting and the caster fingerprint go through here,
# so the override and the DD flag can never disagree between them.
func is_portal_open(portal) -> bool:
	var nid = core.get_node_id(portal)
	if nid != null:
		var store = _get_portal_store()
		if store.has(nid) and store[nid] is Dictionary and store[nid].has("open"):
			return bool(store[nid]["open"])
	var closed = portal.get("Closed")
	if closed != null:
		return not bool(closed)
	return false

# Does this portal draw its pattern as shadow on ground its wall does not
# shade? Unlike `open`, there is no DD flag to fall back on — it is purely the
# mod's, and defaults off so saved maps are unchanged.
func is_portal_projecting(portal) -> bool:
	var nid = core.get_node_id(portal)
	if nid == null:
		return false
	var store = _get_portal_store()
	if store.has(nid) and store[nid] is Dictionary:
		return bool(store[nid].get("project", false))
	return false

# Every projecting portal on the CURRENT level, with its host wall resolved
# from WallID (more robust than get_parent). Driven by the PORTAL store, not
# the caster store: the whole point is that the wall may never have been
# tagged. `wall` is null for an orphan whose WallID points at a deleted or
# redrawn wall — those are picked up by proximity in HeightField instead.
func get_projecting_portal_entries() -> Array:
	var out = []
	var store = _get_portal_store()
	var level = global.World.GetCurrentLevel()
	for pnid in store.keys():
		if not (store[pnid] is Dictionary and bool(store[pnid].get("project", false))):
			continue
		if not global.World.HasNodeID(pnid):
			continue
		var portal = global.World.GetNodeByID(pnid)
		if portal == null or not is_instance_valid(portal):
			continue
		if level != null and not _is_descendant_of(portal, level):
			continue
		var wall = null
		var wid = portal.get("WallID")
		if wid != null and global.World.HasNodeID(wid):
			var w = global.World.GetNodeByID(wid)
			if w != null and is_instance_valid(w):
				wall = w
		out.append({"portal": portal, "wall": wall})
	return out

# Walls that exist ONLY to host a projecting portal: living, visible, on this
# level, and NOT already enabled casters (an enabled caster is in the group
# anyway, and promoting it twice would duplicate it). These join their layer's
# group so a ghost prop exists to draw onto, and contribute nothing else.
func get_projector_walls() -> Array:
	var out = []
	var seen = {}
	var store = _get_store()
	for entry in get_projecting_portal_entries():
		var wall = entry["wall"]
		if wall == null:
			continue
		var wnid = core.get_node_id(wall)
		if wnid == null or seen.has(wnid):
			continue
		if store.has(wnid) and store[wnid] is Dictionary and store[wnid].get("enabled", false):
			continue
		if wall.has_method("is_visible_in_tree") and not wall.is_visible_in_tree():
			continue
		seen[wnid] = true
		out.append(wall)
	return out

func get_config(node) -> Dictionary:
	var cfg = CASTER_DEFAULTS.duplicate()
	var entry = null
	var nid = core.get_node_id(node)
	if nid != null:
		var store = _get_store()
		if store.has(nid):
			entry = store[nid]
			for key in entry.keys():
				cfg[key] = entry[key]
	# A DD WALL is free-standing by nature, so its side defaults to
	# "Wall (both)" — the user's wall silently filling 109% of the map as a
	# Side-A contour (and its door portals cutting nothing, since gaps only
	# apply to the strip) is exactly the failure this prevents. Only an
	# explicit user choice overrides it.
	if (entry == null or not entry.has("side")) and node.get("Joint") != null:
		cfg["side"] = 2
	return cfg

func set_config_value(node, key: String, value):
	var nid = core.get_node_id(node)
	if nid == null:
		outputlog("Cannot store config: node has no node_id", 0)
		return
	var store = _get_store()
	if not store.has(nid):
		# ONLY the changed key. Seeding the full defaults dict here froze
		# "whatever the defaults were on the day this path was first touched"
		# as explicit choices, which breaks computed defaults (a wall's side,
		# art_above's null) and default changes alike.
		store[nid] = {}
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
#
# ABSOLUTE z, accumulated the way Godot does (add while z_as_relative, walking
# up). For paths this equals node.z_index (the Pathways container is at z 0),
# but a WALL's own z is 0 inside DD's Walls container at z 600 — reading just
# z_index would group every wall as "layer 0" and park its shadow underneath
# the map. Walls therefore land in a layer-600 group: shadow over every user
# layer, wall art (Walls container, later in tree order at the same z) over
# its own shadow.
# Accumulated z RELATIVE TO THE LEVEL — the walk stops at the level node and
# never adds its z_index. DD parks a non-active level at z -2000 (compare mode,
# and while the export dialog is open), and reading through it made every layer
# come back 2000 low: 100/200/300/400 became -1900/-1800/-1700/-1600. That
# number is handed to the ghost prop, which is z_as_relative INSIDE that same
# level, so the offset landed a second time and the shadows sank ~2000 below
# the level's own terrain — the "export renders no shadows" bug. Level-relative
# is also what every consumer here means by "layer": grouping keys, the
# fingerprint and the below-containers warning all want the user's layer, not
# wherever DD happens to be parking the level this frame.
func get_caster_layer(node) -> float:
	var level = global.World.GetCurrentLevel()
	var z = 0
	var walker = node
	var guard = 0
	while walker != null and walker is Node2D and guard < 16:
		if level != null and walker == level:
			break
		z += walker.z_index
		if not walker.z_as_relative:
			break
		walker = walker.get_parent()
		guard += 1
	return float(z)

# Cheap change-detector over the enabled caster set, polled by Core. Nothing in
# DD announces "a path was deleted" (or un-deleted, hidden, moved, re-layered,
# or had its points dragged), and without a trigger the height field keeps
# rasterising the stale geometry — the reported symptom was a deleted cliff
# whose shadow stayed and still reacted to the sun sliders (uniform changes
# re-bake from the SAME stale field). Folds in existence, visibility, layer and
# a coordinate checksum, so any of those movements changes the number.
func caster_fingerprint() -> int:
	var h = 0
	var store = _get_store()
	for nid in store.keys():
		# Casters AND blockers both shape the field pass.
		if not (store[nid].get("enabled", false) or store[nid].get("blocks", false)):
			continue
		h = int(h * 31 + str(nid).hash()) % 0x7FFFFFFF
		if not global.World.HasNodeID(nid):
			continue
		var node = global.World.GetNodeByID(nid)
		if node == null or not is_instance_valid(node):
			continue
		var vis = 0
		if node.has_method("is_visible_in_tree") and node.is_visible_in_tree():
			vis = 1
		h = int(h * 31 + int(get_caster_layer(node)) * 2 + vis) % 0x7FFFFFFF
		var pts = node.get("points")
		if pts == null:
			pts = node.get("Points")
		if pts != null:
			var checksum = 0.0
			for p in pts:
				checksum += p.x * 0.13 + p.y * 0.71
			h = int(h * 31 + pts.size() * 131 + int(checksum)) % 0x7FFFFFFF
		# Walls: doors opening/closing (and portals added/moved) change where
		# light passes through the strip, so they must re-rasterise too. Uses
		# the EFFECTIVE state (mod override, else DD's Closed flag).
		if node.get("Joint") != null:
			for portal in get_wall_portals(node):
				if portal == null or not is_instance_valid(portal):
					continue
				# STAMP new portals with the PortalTool panel's default. DD has
				# no placement signal, but this pass visits every portal on a
				# casting wall each tick, so a freshly placed one is stamped
				# (and its wall rebuilt, via the changed fingerprint) within
				# the poll interval. Stamping makes the value durable: changing
				# the tool default later never retroactively flips old portals.
				var pnid = core.get_node_id(portal)
				if pnid != null:
					var pstore = _get_portal_store()
					if not (pstore.has(pnid) and pstore[pnid] is Dictionary):
						pstore[pnid] = {}
					# "No open key" is still what makes a portal NEW here, but the
					# entry may already exist: the Select tool's Project pattern
					# toggle, pattern, top/bottom/tile all write through
					# set_portal_value, which creates {project, pattern, top, ...}
					# with NO "open". The original code REPLACED the whole entry,
					# so the moment the host wall was ticked as a caster this pass
					# wiped an authored pattern and band back to bare defaults
					# (bars silently vanished). MERGE instead — only absent keys
					# are written, so a user setting is never overwritten.
					if not pstore[pnid].has("open"):
						var stamped = PoolStringArray()
						pstore[pnid]["open"] = new_portal_open_default
						stamped.append("open-for-sunlight = %s" % str(new_portal_open_default))
						if not pstore[pnid].has("project"):
							pstore[pnid]["project"] = new_portal_project_default
							stamped.append("project = %s" % str(new_portal_project_default))
						outputlog("portal %s: stamped %s (PortalTool defaults)" % [
							pnid, stamped.join(", ")], 1)
				h = int(h * 31 + (7 if is_portal_open(portal) else 3)) % 0x7FFFFFFF
				h = int(h * 31 + int(portal.global_position.x * 0.53 + portal.global_position.y * 0.29)) % 0x7FFFFFFF
	# PLACEMENT DEFAULT for portals the loop above can never reach. That loop
	# only enters walls that already have an `enabled`/`blocks` caster entry, so
	# a portal dropped on an UNTAGGED wall — precisely the wall this feature
	# exists for, per the control's own tooltip — was never stamped and the
	# PortalTool default silently did nothing. Sweep the level's Portals
	# container as well (same route as get_unattached_portals).
	# Deliberately narrow, and both narrowings are safety, not tidiness:
	#  * ONLY the "project" key. is_portal_open() falls back to DD's own Closed
	#    property when "open" is absent, so stamping "open" for every portal on
	#    the map could flip existing doors' effective state and change how
	#    already-saved maps render. "open" stays where it is, on casting walls.
	#  * ONLY when the default is TRUE. false is already PORTAL_DEFAULTS'
	#    value, so writing it is a semantic no-op that would do nothing but
	#    bloat every saved map with an entry per portal.
	# Writes nothing once stamped, so an unchanged map still fingerprints the
	# same; h is untouched here by design.
	if new_portal_project_default:
		var plevel = global.World.GetCurrentLevel()
		var pcontainer = null
		if plevel != null:
			pcontainer = plevel.get("Portals")
		if pcontainer != null:
			var proj_store = _get_portal_store()
			for pchild in pcontainer.get_children():
				if pchild == null or not is_instance_valid(pchild):
					continue
				# WallID is what identifies a node as a portal at all (Core.gd:95).
				if pchild.get("WallID") == null:
					continue
				var cnid = core.get_node_id(pchild)
				if cnid == null:
					continue
				if not (proj_store.has(cnid) and proj_store[cnid] is Dictionary):
					proj_store[cnid] = {}
				if proj_store[cnid].has("project"):
					continue
				proj_store[cnid]["project"] = true
				outputlog("portal %s: stamped project = true (PortalTool default)" % cnid, 1)
	# PROJECTING PORTALS are driven by the portal store, and their wall may
	# have no caster entry at all — the loop above would never see them. Hash
	# everything the projected quads are built from, so moving a door, editing
	# its band or deleting it re-runs on the next poll like any other change.
	for entry in get_projecting_portal_entries():
		var portal = entry["portal"]
		var pcfg = get_portal_cfg(portal)
		h = int(h * 31 + str(core.get_node_id(portal)).hash()) % 0x7FFFFFFF
		h = int(h * 31 + int(portal.global_position.x * 0.53 + portal.global_position.y * 0.29)) % 0x7FFFFFFF
		h = int(h * 31 + int(float(pcfg.get("bottom", 0.0)) * 10.0)
			+ int(float(pcfg.get("top", 8.0)) * 10.0) * 31
			+ int(float(pcfg.get("tile", 2.5)) * 10.0) * 71
			+ int(pcfg.get("pattern", 0)) * 131) % 0x7FFFFFFF
	return h

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
	_build_portal_tool_ui()
	outputlog("initialised", 0)

# The same "Open for sunlight" choice, offered while PLACING portals: newly
# placed portals are stamped with this value (see caster_fingerprint), and the
# Select-tool toggle then edits that same stored value per portal.
func _build_portal_tool_ui():
	var panel = global.Editor.Toolset.GetToolPanel("PortalTool")
	if panel == null:
		outputlog("PortalTool panel not found", 0)
		return
	var align = core.get_align_vbox(panel)
	if align == null:
		outputlog("PortalTool Align VBox not found", 0)
		return

	var container = VBoxContainer.new()
	container.name = "ElevationShadowsPortalToolDefaults"
	container.add_child(HSeparator.new())
	var row = HBoxContainer.new()
	var label = Label.new()
	label.text = "Open for sunlight"
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.hint_tooltip = ("New portals let the elevation sun through the wall they\n" +
		"sit on. Change a placed portal later via the Select tool.")
	row.add_child(label)
	var toggle = CheckButton.new()
	toggle.pressed = new_portal_open_default
	toggle.connect("toggled", self, "_on_portal_tool_default_toggled")
	row.add_child(toggle)
	container.add_child(row)
	var prow2 = HBoxContainer.new()
	var plabel2 = Label.new()
	plabel2.text = "Project pattern"
	plabel2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	plabel2.hint_tooltip = ("New portals cast their pattern onto the floor even where\n" +
		"the wall casts no shadow. Change a placed portal later via\nthe Select tool.")
	prow2.add_child(plabel2)
	var ptoggle2 = CheckButton.new()
	ptoggle2.pressed = new_portal_project_default
	ptoggle2.connect("toggled", self, "_on_portal_tool_project_default_toggled")
	prow2.add_child(ptoggle2)
	container.add_child(prow2)
	align.add_child(container)
	outputlog("PortalTool UI added", 0)

func _on_portal_tool_default_toggled(pressed):
	new_portal_open_default = pressed
	outputlog("new-portal default open-for-sunlight = %s" % str(pressed), 0)

func _on_portal_tool_project_default_toggled(pressed):
	new_portal_project_default = pressed
	outputlog("new-portal default project-pattern = %s" % str(pressed), 0)

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
	side_btn.hint_tooltip = PATH_SIDE_TOOLTIP
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
	# Label and tooltip are re-targeted per selection (walls read the same
	# value as the CAST side) — see on_selection_changed.
	side_btn.hint_tooltip = PATH_SIDE_TOOLTIP
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

	var blocks_row = HBoxContainer.new()
	var blocks_label = Label.new()
	blocks_label.text = "Stops outside shadows"
	blocks_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	blocks_label.hint_tooltip = ("Shadows cast by anything beyond this wall stop at it —\n" +
		"a house between cliffs keeps its floor plan lit. Open doors\n" +
		"and windows still let outside shadows spill through.\n" +
		"Independent of casting: a wall can block, cast, or both.")
	blocks_row.add_child(blocks_label)
	var blocks_toggle = CheckButton.new()
	blocks_toggle.connect("toggled", self, "_on_st_blocks_toggled")
	blocks_row.add_child(blocks_toggle)
	container.add_child(blocks_row)
	st_ui["blocks"] = blocks_toggle

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

	# Portal section, shown when a door/window is selected. DD's own
	# Portal.Closed has no reachable UI in this build, so this is the user's
	# way to shut a doorway against the sun.
	var pcontainer = VBoxContainer.new()
	pcontainer.name = "ElevationShadowsPortalTool"
	pcontainer.visible = false
	pcontainer.add_child(HSeparator.new())
	var prow = HBoxContainer.new()
	var plabel = Label.new()
	plabel.text = "Open for sunlight"
	plabel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	plabel.hint_tooltip = ("Whether this door/window lets the elevation sun through\n" +
		"the wall it sits on: open = a gap in the wall's shadow (and\n" +
		"cliff shadows behind pass through the doorway), off = the\n" +
		"wall casts as if solid. Only matters on walls that cast\n" +
		"elevation shadows.")
	prow.add_child(plabel)
	var ptoggle = CheckButton.new()
	ptoggle.connect("toggled", self, "_on_st_portal_open_toggled")
	prow.add_child(ptoggle)
	pcontainer.add_child(prow)

	# The "fake shadow": project this portal's pattern onto ground its wall
	# does not shade. Independent of the toggle above — a CLOSED door projects.
	var jrow = HBoxContainer.new()
	var jlabel = Label.new()
	jlabel.text = "Project pattern"
	jlabel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	jlabel.hint_tooltip = ("Cast this opening's pattern onto the floor even where the\n" +
		"wall casts no shadow — a house set to shade only its outside\n" +
		"still gets window patterns on the inside floor, and it works\n" +
		"with no elevation shadows on the map at all.\n" +
		"Independent of \"Open for sunlight\": a closed door projects.\n" +
		"Needs a Light pattern below — a plain opening has nothing to cast.")
	jrow.add_child(jlabel)
	var jtoggle = CheckButton.new()
	jtoggle.connect("toggled", self, "_on_st_portal_project_toggled")
	jrow.add_child(jtoggle)
	pcontainer.add_child(jrow)
	st_ui["portal_project"] = jtoggle

	# Light pattern + opening geometry: what shape the light takes through
	# this opening, and where the opening sits in the wall's face.
	var pat_row = HBoxContainer.new()
	var pat_label = Label.new()
	pat_label.text = "Light pattern"
	pat_label.rect_min_size = Vector2(104, 0)
	pat_label.hint_tooltip = ("Shape of the light coming through: bars, window panes,\n" +
		"lattice... The pattern is projected onto the ground and\n" +
		"skews/stretches with the sun, like the classic window\ncross on a floor.")
	pat_row.add_child(pat_label)
	var pat_option = OptionButton.new()
	for name in PATTERN_NAMES:
		pat_option.add_item(name)
	pat_option.add_item("Custom texture...")  # index == PATTERN_CUSTOM
	pat_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pat_option.connect("item_selected", self, "_on_st_portal_pattern_selected")
	pat_row.add_child(pat_option)
	pcontainer.add_child(pat_row)
	st_ui["portal_pattern"] = pat_option

	# The Custom texture's image: one compact row (the panel is height-budgeted),
	# shown only while Custom is the selected pattern. Alpha is the blocker, same
	# contract as the generated patterns — but binary: any alpha > 0 blocks fully.
	var cust_row = HBoxContainer.new()
	var cust_btn = Button.new()
	cust_btn.text = "Image..."
	cust_btn.hint_tooltip = ("Pick a PNG/WebP whose alpha is the pattern: any pixel with\n" +
		"non-0% opacity blocks the light completely, fully transparent\n" +
		"pixels let it through. Tiles at the Pattern size above.")
	cust_btn.connect("pressed", self, "_on_st_portal_pattern_file_pressed")
	cust_row.add_child(cust_btn)
	var cust_label = Label.new()
	cust_label.text = "(no image)"
	cust_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cust_label.clip_text = true
	cust_label.modulate = Color(1, 1, 1, 0.6)
	cust_row.add_child(cust_label)
	cust_row.visible = false
	pcontainer.add_child(cust_row)
	st_ui["portal_custom_row"] = cust_row
	st_ui["portal_custom_label"] = cust_label

	var top_row = HBoxContainer.new()
	var top_label = Label.new()
	top_label.text = "Opening top (ft)"
	top_label.rect_min_size = Vector2(104, 0)
	top_label.hint_tooltip = ("Lintel height: the wall above it still shades, so the beam\n" +
		"through the opening ends at a realistic distance.")
	top_row.add_child(top_label)
	var top_spin = SpinBox.new()
	top_spin.min_value = 0.5
	top_spin.max_value = 240.0
	top_spin.step = 0.5
	top_spin.value = 8.0
	top_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_spin.connect("value_changed", self, "_on_st_portal_top_changed")
	top_row.add_child(top_spin)
	pcontainer.add_child(top_row)
	st_ui["portal_top"] = top_spin

	var bot_row = HBoxContainer.new()
	var bot_label = Label.new()
	bot_label.text = "Opening bottom (ft)"
	bot_label.rect_min_size = Vector2(104, 0)
	bot_label.hint_tooltip = ("Sill height: 0 for doors. Raise for windows — the wall\n" +
		"below the sill shades the ground nearest the wall.")
	bot_row.add_child(bot_label)
	var bot_spin = SpinBox.new()
	bot_spin.min_value = 0.0
	bot_spin.max_value = 239.0
	bot_spin.step = 0.5
	bot_spin.value = 0.0
	bot_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bot_spin.connect("value_changed", self, "_on_st_portal_bottom_changed")
	bot_row.add_child(bot_spin)
	pcontainer.add_child(bot_row)
	st_ui["portal_bottom"] = bot_spin

	var tile_row = HBoxContainer.new()
	var tile_label = Label.new()
	tile_label.text = "Pattern size (ft)"
	tile_label.rect_min_size = Vector2(104, 0)
	tile_label.hint_tooltip = "One bar / pane / plus per this many feet."
	tile_row.add_child(tile_label)
	var tile_spin = SpinBox.new()
	tile_spin.min_value = 0.5
	tile_spin.max_value = 20.0
	tile_spin.step = 0.25
	tile_spin.value = 2.5
	tile_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tile_spin.connect("value_changed", self, "_on_st_portal_tile_changed")
	tile_row.add_child(tile_spin)
	pcontainer.add_child(tile_row)
	st_ui["portal_tile"] = tile_spin

	align.add_child(pcontainer)
	st_ui["portal_container"] = pcontainer
	st_ui["portal_open"] = ptoggle

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
	var portal = null
	for node in selected:
		if path == null and core.is_path_node(node):
			path = node
		elif portal == null and core.is_portal_node(node):
			portal = node

	_current_portal = portal
	if st_ui.has("portal_container"):
		st_ui["portal_container"].visible = portal != null
		if portal != null:
			var pcfg = get_portal_cfg(portal)
			_syncing = true
			st_ui["portal_open"].pressed = is_portal_open(portal)
			if st_ui.has("portal_pattern"):
				st_ui["portal_project"].pressed = bool(pcfg.get("project", false))
				st_ui["portal_pattern"].selected = int(pcfg.get("pattern", 0))
				st_ui["portal_top"].value = float(pcfg.get("top", 8.0))
				st_ui["portal_bottom"].value = float(pcfg.get("bottom", 0.0))
				st_ui["portal_tile"].value = float(pcfg.get("tile", 2.5))
				_update_custom_pattern_row(pcfg)
			_syncing = false

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
	st_ui["side"].text = side_label(path, int(cfg.get("side", 0)))
	st_ui["side"].hint_tooltip = WALL_SIDE_TOOLTIP if is_wall_node(path) else PATH_SIDE_TOOLTIP
	st_ui["height_slider"].value = h_ft
	st_ui["height_spin"].value = h_ft
	if st_ui.has("art_above"):
		st_ui["art_above"].pressed = get_art_above(path)
	if st_ui.has("blocks"):
		st_ui["blocks"].pressed = cfg.get("blocks", false)
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
	st_ui["side"].text = side_label(_current_path, next_side)

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

func _on_st_blocks_toggled(pressed):
	if _syncing or _current_path == null:
		return
	set_config_value(_current_path, "blocks", pressed)

func _on_st_portal_pattern_selected(index):
	if _syncing or _current_portal == null:
		return
	set_portal_value(_current_portal, "pattern", int(index))
	_update_custom_pattern_row(get_portal_cfg(_current_portal))
	# First time Custom is picked on a portal there is nothing to show yet —
	# go straight to the image picker instead of a silent plain opening.
	if int(index) == PATTERN_CUSTOM and str(get_portal_cfg(_current_portal).get("pattern_file", "")) == "":
		_open_pattern_file_dialog()

func _on_st_portal_pattern_file_pressed():
	if _current_portal == null:
		return
	_open_pattern_file_dialog()

# A plain Godot FileDialog over the filesystem (created once, reused). DD has
# no reusable asset-browser dialog surfaced to mods, and the pattern image is
# a mod-side resource anyway — it never needs to live in an asset pack.
func _open_pattern_file_dialog():
	if _pattern_file_dialog == null or not is_instance_valid(_pattern_file_dialog):
		var dlg = FileDialog.new()
		dlg.mode = FileDialog.MODE_OPEN_FILE
		dlg.access = FileDialog.ACCESS_FILESYSTEM
		dlg.window_title = "Light pattern image (alpha > 0 blocks light)"
		dlg.resizable = true
		dlg.rect_min_size = Vector2(700, 500)
		dlg.filters = PoolStringArray([
			"*.png ; PNG images", "*.webp ; WebP images",
			"*.jpg, *.jpeg ; JPEG images (no alpha — blocks everywhere)",
			"*.bmp ; BMP images", "*.tga ; TGA images"])
		dlg.connect("file_selected", self, "_on_st_portal_pattern_file_selected")
		# Start somewhere sane; the dialog keeps its last directory afterwards.
		var home = OS.get_environment("HOME")
		if home != "":
			dlg.current_dir = home
		global.Editor.add_child(dlg)
		_pattern_file_dialog = dlg
	# The dialog outlives the selection — remember whose portal it was opened
	# for, so a selection change while it is up cannot retarget the pick.
	_pattern_file_portal = _current_portal
	_pattern_file_dialog.popup_centered()

func _on_st_portal_pattern_file_selected(path):
	var portal = _pattern_file_portal
	_pattern_file_portal = null
	if portal == null or not is_instance_valid(portal):
		outputlog("pattern image picked but the portal is gone — ignored", 0)
		return
	# Re-picking a path must beat the renderer's texture cache (the file may
	# have been edited on disk since the last load).
	if shadow_renderer != null:
		shadow_renderer.invalidate_custom_pattern(str(path))
	set_portal_value(portal, "pattern_file", str(path))
	if int(get_portal_cfg(portal).get("pattern", 0)) != PATTERN_CUSTOM:
		set_portal_value(portal, "pattern", PATTERN_CUSTOM)
	if portal == _current_portal:
		_syncing = true
		st_ui["portal_pattern"].selected = PATTERN_CUSTOM
		_syncing = false
		_update_custom_pattern_row(get_portal_cfg(portal))

# The pick-file row: only visible while Custom is the selected pattern, label
# shows the image's basename (full path in the tooltip).
func _update_custom_pattern_row(pcfg: Dictionary):
	if not st_ui.has("portal_custom_row"):
		return
	var is_custom = int(pcfg.get("pattern", 0)) == PATTERN_CUSTOM
	st_ui["portal_custom_row"].visible = is_custom
	var pfile = str(pcfg.get("pattern_file", ""))
	st_ui["portal_custom_label"].text = pfile.get_file() if pfile != "" else "(no image)"
	st_ui["portal_custom_label"].hint_tooltip = pfile

func _on_st_portal_top_changed(value):
	if _syncing or _current_portal == null:
		return
	set_portal_value(_current_portal, "top", float(value))

func _on_st_portal_bottom_changed(value):
	if _syncing or _current_portal == null:
		return
	set_portal_value(_current_portal, "bottom", float(value))

func _on_st_portal_tile_changed(value):
	if _syncing or _current_portal == null:
		return
	set_portal_value(_current_portal, "tile", float(value))

func _on_st_portal_open_toggled(pressed):
	if _syncing or _current_portal == null:
		return
	var nid = core.get_node_id(_current_portal)
	if nid == null:
		outputlog("Cannot store portal state: portal has no node_id", 0)
		return
	var store = _get_portal_store()
	if not (store.has(nid) and store[nid] is Dictionary):
		store[nid] = {}
	store[nid]["open"] = pressed
	outputlog("portal %s: open for sunlight = %s" % [nid, str(pressed)], 0)
	if core != null:
		core.request_rebuild(false, true)

func _on_st_portal_project_toggled(pressed):
	if _syncing or _current_portal == null:
		return
	var nid = core.get_node_id(_current_portal)
	if nid == null:
		outputlog("Cannot store portal state: portal has no node_id", 0)
		return
	var store = _get_portal_store()
	if not (store.has(nid) and store[nid] is Dictionary):
		store[nid] = {}
	store[nid]["project"] = pressed
	outputlog("portal %s: project pattern = %s" % [nid, str(pressed)], 0)
	# FIELD rebuild, not uniforms-only: turning this on may promote an untagged
	# wall to a projector-only caster, which creates a layer group and a ghost
	# prop that update_uniforms alone would never build.
	if core != null:
		core.request_rebuild(false, true)

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
