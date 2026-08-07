shader_type canvas_item;
render_mode blend_mul;

// PORTAL BEAM MASK — the fraction of the solid wall's shadow that SURVIVES
// the opening, per ground pixel. Rendered into a white-based mask viewport
// (one per layer group that has open portals) and composed with blend_mul,
// so overlapping portals multiply like serial transmissions — never
// double-dark, never double-carved — and f = 1 at every quad edge by
// construction, so the quad's outline cannot render. This replaced BOTH
// earlier schemes (additive rebuild quads, then subtractive erase quads):
// two independent cold-read designs converged on it 2026-08-07.
//
// The march bakes the wall as SOLID; this mask carves the light back out:
//
//   shadow_final = march * f
//   f = 1 - (1-bar) * (S(h_top/d) - S(h_bottom/d)) / S(h_wall/d)
//
// with S(t) = smoothstep(tan_lo, tan_hi, t) — the march's own coverage
// function over the sun's angular band, so every edge fades with the real
// penumbra:
//   * d inside the sill's reach: S(top)==S(bottom)==1 -> f = 1
//     (the un-carved near band IS the march's sill shadow);
//   * opaque pattern bars: bar = 1 -> f = 1 exactly
//     (bars keep the march's wall-shadow strength, whatever it is);
//   * beyond d = h_top/tan_lo the whole sun band clears the lintel:
//     S(top)-S(bottom) -> 0 -> f = 1 (the lintel cap is just the march's
//     shadow continuing past the beam, ending in its own penumbra).
//
// UV.x tiles the pattern across the span, UV.y up the opening's face (the
// centre ray's crossing height in tiles), so patterns stay authored face-on
// and skew/stretch with the sun. COLOR.g (vertex colour — the mesh is built
// with compress flags 0 so it stays float) interpolates the ground distance
// d across the quad. Texture ALPHA is the blocker (opaque bars shade);
// sampled explicitly — touching COLOR disables the automatic texture
// multiply (COLOR_USED trap).
//
// blend_mul on a transparent render target is dst.rgb *= src.rgb (and
// dst.a *= src.a), which is why the viewport lays down an opaque white base
// first: the target clears to (0,0,0,0) and multiplying against that would
// zero everything.

uniform float tan_lo = 0.4;        // tan(altitude - spread), same as the march
uniform float tan_hi = 0.9;        // tan(altitude + spread)
uniform float h_bottom_px = 0.0;   // sill height, in world px of height
uniform float h_top_px = 400.0;    // lintel height
uniform float h_wall_px = 700.0;   // wall top
uniform float d0_px = 1.0;         // ground distance at the quad's near edge
uniform float d1_px = 1000.0;      // ... and at its far edge
uniform float has_pattern = 0.0;   // 0 = plain opening (bar = 0 everywhere)

void fragment() {
	float d = max(1.0, mix(d0_px, d1_px, COLOR.g));
	float sw = smoothstep(tan_lo, tan_hi, h_wall_px / d);
	float st = smoothstep(tan_lo, tan_hi, h_top_px / d);
	float sb = smoothstep(tan_lo, tan_hi, h_bottom_px / d);
	float bar = has_pattern > 0.5 ? texture(TEXTURE, UV).a : 0.0;
	// S(t)-S(b) <= S(w) since h_b < h_t < h_w, so f stays in [bar, 1]. The
	// 0.05 floor only engages out past the shadow's end, where f is 1 anyway.
	float f = 1.0 - (1.0 - bar) * max(0.0, st - sb) / max(0.05, sw);
	f = clamp(f, 0.0, 1.0);
	COLOR = vec4(f, f, f, 1.0);
}
