shader_type canvas_item;

// Turns the baked shadow STRENGTH (stored in red) back into a coloured shadow.
//
// Why the strength is not simply stored in alpha: Godot 3's GLES3 backend picks
// an RGB10_A2 render target for 2D / disable_3d viewports, which gives alpha only
// TWO BITS. Anything written to COLOR.a in the bake was snapped to {0, 1/3, 2/3,
// 1} — and since the march can never exceed `opacity` (0.66), exactly three
// values survived: 0.00, 0.33, 0.67. That is the entire "only two kinds of
// shadow, the fade does nothing" bug: the gradient was computed correctly and
// then destroyed on write.
//
// Red has 10 bits under the same format (8 under RGBA8), so the gradient survives
// either way. One texture fetch per screen pixel, negligible beside the march.
//
// PROJECTED PORTAL PATTERNS composite here, with max() rather than a sum. The
// projection viewport is the same size and rect as the bake, so UV maps 1:1.
// max() is load-bearing, not a convenience: projected bars are drawn at the SAME
// strength as a real wall shadow, so wherever real shadow already covers that
// floor the max is the value already there and the projection is an exact no-op.
// That is what lets the feature run unconditionally and never double-darken.
// `proj_opacity` is the march's own `opacity` (Strength); the bake's red already
// has it baked in, the projection does not, so it is applied here — which also
// keeps Strength a live uniform with no rebuild, like the tint.

uniform vec4 shadow_color : hint_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform sampler2D proj_tex;
uniform float use_proj = 0.0;
uniform float proj_opacity = 0.55;

void fragment() {
	float a = texture(TEXTURE, UV).r;
	if (use_proj > 0.5) {
		a = max(a, texture(proj_tex, UV).r * proj_opacity);
	}
	COLOR = vec4(shadow_color.rgb, a);
}
