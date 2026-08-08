shader_type canvas_item;
render_mode blend_mix;

// PROJECTED PORTAL PATTERN — the portal's pattern drawn as POSITIVE shadow on
// ground the wall does not shade. The sibling of PatternShadow.shader: that one
// carves light OUT of a solid wall shadow and only exists where the wall casts;
// this one puts the bars down on their own, so a house set to shade only its
// exterior still gets its windows' patterns on the interior floor.
//
//   p = bar * (S(h_top/d) - S(h_bottom/d)),   S = smoothstep(tan_lo, tan_hi, .)
//
// S is the march's own coverage function over the sun's angular band, so the
// near (sill) and far (lintel) ends fade with the same real penumbra the rest
// of the mod uses, and the opening's top/bottom feet drive the footprint.
//
// Composited by ShadowDisplay as max(bake.r, p * opacity) — NOT added. At equal
// strength `max` makes the already-shadowed cases exact no-ops: inside a carved
// beam the bars are already at march strength, and inside a solid wall shadow a
// shadow pattern is not visible anyway. That is why this feature needs no
// "is the wall casting here?" conditional at all, and why it can never
// double-darken.
//
// Rendered into a TRANSPARENT-based viewport with plain MIX (PatternShadow's
// white base exists only because blend_mul needs one). Overlapping portals then
// compose "over" — p2 + p1*(1-p2) — which saturates instead of doubling.
//
// COLOR.g interpolates ground distance d across the quad; the mesh must keep
// FLOAT vertex colours (compress flags 0). Texture ALPHA is the blocker,
// sampled explicitly — touching COLOR disables the automatic texture multiply
// (the COLOR_USED trap).

uniform float tan_lo = 0.4;        // tan(altitude - spread), same as the march
uniform float tan_hi = 0.9;        // tan(altitude + spread)
uniform float h_bottom_px = 0.0;   // sill height, in world px of height
uniform float h_top_px = 400.0;    // lintel height
uniform float d0_px = 1.0;         // ground distance at the quad's near edge
uniform float d1_px = 1000.0;      // ... and at its far edge
uniform float has_pattern = 0.0;   // 0 = plain opening: nothing to cast

void fragment() {
	float d = max(1.0, mix(d0_px, d1_px, COLOR.g));
	float st = smoothstep(tan_lo, tan_hi, h_top_px / d);
	float sb = smoothstep(tan_lo, tan_hi, h_bottom_px / d);
	float bar = has_pattern > 0.5 ? texture(TEXTURE, UV).a : 0.0;
	float p = clamp(bar * max(0.0, st - sb), 0.0, 1.0);
	// rgb stays 1: MIX multiplies src.rgb by src.a, so p must appear ONCE.
	COLOR = vec4(1.0, 1.0, 1.0, p);
}
