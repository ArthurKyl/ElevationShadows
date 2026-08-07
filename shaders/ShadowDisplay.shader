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

uniform vec4 shadow_color : hint_color = vec4(0.0, 0.0, 0.0, 1.0);

void fragment() {
	COLOR = vec4(shadow_color.rgb, texture(TEXTURE, UV).r);
}
