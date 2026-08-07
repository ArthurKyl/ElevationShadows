shader_type canvas_item;
render_mode blend_add;

// Writes a copied path's ART ALPHA into one colour channel of the mask raster.
//
// The per-layer art mask stores up to three layers per render target (R, G, B
// = slot 0, 1, 2 of its chain), exactly like the height field's channel
// packing. Each copied Line2D gets this material with `channel` set to its
// slot's colour, so overlapping paths on the same layer accumulate additively
// (clamped on read) without touching the other layers' channels.
//
// The texture MUST be sampled explicitly. Godot 3 trap: the automatic
// "multiply by texture" step is compiled out of the canvas shader as soon as
// user fragment code touches COLOR (`#if !defined(COLOR_USED)` in
// canvas.glsl), so reading COLOR here yields only the vertex colour — alpha
// 1.0 across the whole Line2D strip. That turned the mask into a solid band
// covering the art's transparent margins, which read on screen as the shadow
// starting ~50px outside the texture (diagnosed by the mask probe: a hard
// 0/1 band with no texture detail).
// Output alpha is 1 so blend_add contributes channel * a exactly once.
//
// SHADOW INSET is an ALPHA EROSION across the strip (UV.y spans 0..1 across a
// Line2D's width in every texture mode), NOT a width change. Shrinking the
// Line2D's width was tried first and produced "the texture slides along the
// path": with TILE mode the tiling count derives from the width, so any width
// change rescales the art along the line's length. Eroding in v moves the
// alpha edge purely inward/outward: positive inset takes the MIN alpha over
// taps offset across the width (shadow tucks further under the art), negative
// takes the MAX (mask grows, shadow peeks out). Taps are clamped to 0..1 in v
// so REPEAT-flagged textures cannot wrap alpha in from the opposite edge.

uniform vec3 channel = vec3(1.0, 0.0, 0.0);
uniform float inset_uv = 0.0;   // inset_px / line width

float tap(sampler2D tex, vec2 uv, float dv) {
	return texture(tex, vec2(uv.x, clamp(uv.y + dv, 0.0, 1.0))).a;
}

void fragment() {
	float a = texture(TEXTURE, UV).a;
	if (inset_uv > 0.0001) {
		a = min(a, tap(TEXTURE, UV, inset_uv));
		a = min(a, tap(TEXTURE, UV, -inset_uv));
		a = min(a, tap(TEXTURE, UV, inset_uv * 0.5));
		a = min(a, tap(TEXTURE, UV, -inset_uv * 0.5));
	} else if (inset_uv < -0.0001) {
		a = max(a, tap(TEXTURE, UV, -inset_uv));
		a = max(a, tap(TEXTURE, UV, inset_uv));
		a = max(a, tap(TEXTURE, UV, -inset_uv * 0.5));
		a = max(a, tap(TEXTURE, UV, inset_uv * 0.5));
	}
	COLOR = vec4(channel * a, 1.0);
}
