shader_type canvas_item;
render_mode blend_add;

// PROJECTED PORTAL SHADOW — the quad a doorway/window's light-opening throws
// onto the ground, rendered into the wall's shadow BAKE (additive into the
// red strength channel, like the march's own output).
//
// The mesh is a parallelogram: portal span x shadow direction, built at bake
// time by ShadowRenderer._rebuild_pattern_quads() from the current sun. UV.y
// runs up the opening's face (so the texture is authored "face-on" like a
// real window), UV.x along the span; the projection skew/stretch is entirely
// in the mesh, not here.
//
// The texture's ALPHA is the blocker: opaque muntins/bars shade, transparent
// panes pass light. Sampled explicitly — touching COLOR disables the
// automatic texture multiply (COLOR_USED trap), which is also what lets the
// untextured solid quads (sill / above-lintel wall bands) read alpha 1.
// COLOR (vertex colour) carries the tail fade on the resume band's end.

uniform float strength = 0.55;

void fragment() {
	float a = texture(TEXTURE, UV).a;
	float v = a * strength * COLOR.a;
	COLOR = vec4(v, v, v, 1.0);
}
