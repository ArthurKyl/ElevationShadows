shader_type canvas_item;
render_mode blend_mix;

// TRACED OBJECT SHADOW — the literal question, asked per pixel.
//
// For each ground pixel, walk back along the sun sampling the OBJECT'S OWN
// texture. If any step lands on drawn art, this pixel is shadowed, and its
// darkness comes from how far back that hit was. That is the definition of a
// shadow, so the near edge, the far edge, concavities and the object's real
// holes all fall out of one expression instead of being constructed.
//
// It replaced one strip per silhouette column, which streaked badly on screen.
// The cause was arithmetic, not gaps: every strip faded from ITS OWN column's
// edge, so two neighbours covering the same patch of ground computed different
// darkness, and each of thirty-odd seams became a visible step. Profile mode
// emits a single quad and showed none of it, which is what isolated the cause.
// One surface cannot have that problem — there is one continuous function.
//
// Coverage per hit is the same smoothstep band the march and the portal beams
// use, so an object's shadow softens with distance exactly like everything else
// in this mod.
//
// The fragment's world position is reconstructed from the quad's UVs rather
// than interpolated as a varying: canvas_item shaders have no UV2, and the
// quad's own UVs are free here because the pattern's tiling coordinates are
// computed from world position too.

// A CONSTANT loop bound with an early break, not a uniform bound: a
// uniform-bounded loop is a portability risk in GLES3.
const int MAX_STEPS = 48;

uniform vec2 quad_o = vec2(0.0);        // world position of the quad's UV(0,0) corner
uniform vec2 quad_u = vec2(1.0, 0.0);   // world vector along UV.x
uniform vec2 quad_v = vec2(0.0, 1.0);   // world vector along UV.y
uniform vec2 sun_dir = vec2(0.0, 1.0);  // unit, DOWNSUN — the way shadows fall
uniform vec2 perp_dir = vec2(1.0, 0.0); // unit, perpendicular
uniform float t_min = 1.0;              // nearest the shadow can start, world px
uniform float t_max = 100.0;            // furthest it can reach
uniform int steps = 16;
uniform float tan_lo = 0.4;             // tan(altitude - spread), same as the march
uniform float tan_hi = 0.9;             // tan(altitude + spread)
uniform float h_bottom_px = 0.0;
uniform float h_top_px = 400.0;
uniform sampler2D obj_tex;              // the object's OWN art
uniform vec2 obj_ix = vec2(1.0, 0.0);   // world -> texture UV, x column
uniform vec2 obj_iy = vec2(0.0, 1.0);   // ... y column
uniform vec2 obj_io = vec2(0.0);        // ... origin
uniform float width_scale = 1.0;        // the width adjust, across the sun
uniform float width_mid = 0.0;          // ... about this perp coordinate
uniform float alpha_cut = 0.02;         // "the artist drew something here"
uniform float tile_px = 128.0;          // pattern tile, world px
uniform float tan_c = 0.7;              // tan(altitude), for the pattern's v
uniform float u_origin = 0.0;           // pattern anchored to the OBJECT, not
uniform float v_origin = 0.0;           // to world space — see below

void fragment() {
	vec2 world = quad_o + quad_u * UV.x + quad_v * UV.y;
	// The width adjust scales the silhouette across the sun about width_mid, and
	// the renderer has already widened the QUAD to match. The march has to be
	// widened with it, or a positive adjust would draw nothing new: the art
	// being sampled has not moved, so the extra ground would simply miss it and
	// the control would look broken in one direction only. So walk the ray from
	// the ground point mapped BACK through that same scale.
	//
	// Hoisted out of the loop: the unscale touches only the perp component and
	// sun_dir has none, so unscale(world - sun_dir*t) is exactly
	// unscale(world) - sun_dir*t. At the default adjust width_scale is 1 and
	// this is the identity. It is > 0 by construction (the renderer floors the
	// emitter width at MIN_EMITTER_PX); the max() is belt and braces.
	float inv_s = 1.0 / max(0.0001, width_scale);
	vec2 march_o = world
		+ perp_dir * ((dot(world, perp_dir) - width_mid) * (inv_s - 1.0));
	// max(1.0, float(steps)), not float(max(1, steps)): the integer overload of
	// max() is one more thing to be wrong about in a file that does not fail
	// loudly.
	float n = max(1.0, float(steps));
	float cov = 0.0;
	for (int i = 0; i < MAX_STEPS; i++) {
		if (i >= steps) {
			break;
		}
		// Sample at the CENTRE of each interval, so the two ends are not
		// weighted differently from the middle.
		float t = mix(t_min, t_max, (float(i) + 0.5) / n);
		vec2 w = march_o - sun_dir * t;
		vec2 uv = obj_io + obj_ix * w.x + obj_iy * w.y;
		if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
			continue;
		}
		if (texture(obj_tex, uv).a <= alpha_cut) {
			continue;
		}
		// The fraction of the sun's disc this occluder blocks from `t` away.
		// max(), not sum: overlapping hits along one ray are the same occluder
		// seen at different depths, not independent blockers.
		//
		// The division is safe: the renderer floors t_min at 1.0 and t is
		// sampled inside [t_min, t_max]. With h_bottom_px == 0 the second term
		// is smoothstep(.., 0.0) == 0 and this is just the top's coverage. With
		// h_bottom_px > 0 both terms saturate to 1 as t gets small, so the
		// difference goes to 0 near the object — correct, that is light passing
		// underneath a raised band.
		float c = smoothstep(tan_lo, tan_hi, h_top_px / t)
			- smoothstep(tan_lo, tan_hi, h_bottom_px / t);
		cov = max(cov, c);
	}
	// The pattern tiles in WORLD space but is anchored to the object: u_origin
	// and v_origin are the object's own left edge and leading edge, so the
	// phase is fixed to the prop rather than to where it sits on the map or
	// which way the sun points. `world`, not `march_o` — the pattern lies on the
	// ground the quad actually covers, so it must not be unscaled.
	//
	// No has_pattern flag, unlike ProjectedPattern.shader: the object path
	// already `continue`s out on a null pattern texture and Solid resolves to an
	// opaque one, so TEXTURE is always bound here. Sampled explicitly — touching
	// COLOR disables the automatic texture multiply (the COLOR_USED trap).
	vec2 puv = vec2(
		(dot(world, perp_dir) - u_origin) / tile_px,
		(dot(world, sun_dir) - v_origin) * tan_c / tile_px);
	float bar = texture(TEXTURE, puv).a;
	float p = clamp(cov * bar, 0.0, 1.0);
	// rgb stays 1: MIX multiplies src.rgb by src.a, so p must appear ONCE.
	COLOR = vec4(1.0, 1.0, 1.0, p);
}
