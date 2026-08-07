shader_type canvas_item;

// ELEVATION SHADOW — per-pixel sun march over the height field, ONE PASS PER
// CASTER LAYER.
//
// Rather than marching K separate rays to get a soft edge, this computes the
// HORIZON ANGLE: for every step toward the sun, the minimum tangent a light ray
// would need in order to clear that obstruction. The largest such value along
// the march is the horizon. Comparing it against the sun's angular extent gives
// occlusion in a single pass — one texture fetch per step instead of K.
//
// Penumbra widening with distance falls out for free. Near an occluder the
// horizon tangent changes rapidly across a pixel or two; far away it changes
// slowly. So one fixed ANGULAR softness band maps to a narrow spatial gradient
// close to the cliff and a wide one far from it, which is what real penumbra
// does. No blur pass, no variable-radius kernel.
//
// ---------------------------------------------------------------------------
// PER-LAYER ATTRIBUTION
// ---------------------------------------------------------------------------
// There is one bake, one shadow node and one instance of this material PER
// DISTINCT CASTER LAYER (DD's Layer dropdown == the path's z_index). Each
// shadow node sits at z = its layer, over every lower layer's artwork — "a
// higher caster's shadow must darken a lower caster's art" — while its own
// layer's art is protected by the per-layer art mask (below) and same-layer
// objects choose their side with DD's Bring to front / Send to back.
//
// For that to work each pass must emit only the shadow that ITS layer owns.
// So the height field does not store one summed elevation in red; it stores each
// layer's contribution in its own colour channel:
//
//     TEXTURE (field A)  R,G,B = slot 0, 1, 2
//     field_b            R,G,B = slot 3, 4, 5     (bound to field A, and zeroed
//                                                  by use_field_b, when unused)
//
//   * TOTAL elevation = the sum of all six channels. Both the receiving ground
//     (h0) and the occluder height use the total, so shadow LENGTHS are correct
//     even where a shadow falls across another layer's tiers.
//   * WHICH LAYER owns an occluder = the highest slot whose own channel rises
//     between the shaded pixel and the sampled point.
//
// Overlap between passes is cancelled analytically rather than left to alpha
// compositing. Each pass tracks two numbers:
//
//     mine  = strongest shadow from occluders this slot owns
//     above = strongest shadow from occluders a HIGHER slot owns
//
// and emits  out = (mine - above) / (1 - above).  Because the sprites composite
// multiplicatively over each other (1 - out), the product telescopes to exactly
// max(all slots) — so N overlapping layers darken the ground once, not N times.
// On a given layer's own artwork the lower sprites are hidden behind the art and
// only the higher ones show through, which is precisely "darkened by shadows
// from above, never by its own".

uniform vec2 sun_dir_px = vec2(0.0, -1.0);   // unit vector TOWARD the sun, world px, +y down
uniform vec2 raster_size_px = vec2(1.0);     // world px covered by the field
uniform float tier_px = 256.0;               // world px of height per tier
uniform float height_divisor = 16.0;         // decodes a channel -> tiers
uniform float tan_lo = 0.4;                  // tan(altitude - spread): below this, fully lit
uniform float tan_hi = 0.9;                  // tan(altitude + spread): above this, fully shadowed
uniform float base_stride_px = 8.0;          // first march step, in world px
uniform float stride_growth = 1.03;          // each step is this much longer
uniform int steps = 128;
uniform float opacity = 0.55;
uniform float self_bias_tiers = 0.05;        // ignore sub-tier noise in the total field
uniform float attr_bias_tiers = 0.05;        // ignore sub-tier noise in a single slot
uniform float max_tiers = 4.0;               // tallest stacked elevation on the map

// Second raster chain, carrying slots 3..5. When the map has three or fewer
// caster layers this is bound to field A and use_field_b is 0, so its
// contribution is multiplied away — no extra render target is allocated.
uniform sampler2D field_b;
uniform float use_field_b = 0.0;

uniform int group_slot = 0;                  // which slot THIS pass renders
uniform float has_above = 0.0;               // 1.0 if any slot sits above this one

// Per-layer art mask: the artwork of THIS layer's paths flagged "Art above
// shadow", rasterised into this slot's channel (same chain/channel packing as
// the height field). The shadow is attenuated by it, so it slides UNDER that
// artwork and the texture's own alpha edge becomes the visible boundary.
// Own-layer only by construction: higher layers' sprites never read this slot's
// channel, so a 400 shadow still darkens 200 cliff art — which is what the old
// GLOBAL art mask got wrong.
uniform sampler2D art_mask;
uniform float use_art_mask = 0.0;
uniform int mask_channel = 0;

// Shadow BLOCKER raster ("Stops outside shadows" strips, binary, unblurred).
// When a march step lands on it, the march ends: occluders beyond the blocker
// never darken this pixel. Deliberately non-physical — a mountain's shadow
// really would cover a house's interior, but the battlemap shows the floor
// plan and the floor plan should stay lit. Open portals are already cut out
// of the strip, so doorways let outside shadows spill through.
uniform sampler2D blocker_tex;
uniform float use_blocker = 0.0;

const int MAX_STEPS = 512;

// The sampler MUST be passed in. Godot's shader language only exposes built-ins
// such as TEXTURE inside the function they belong to, so reading TEXTURE from a
// helper fails to compile with "Unknown identifier in expression: TEXTURE" — and
// a failed compile silently falls back to drawing the raw height field.
// Same pattern as SoftShadows' src_alpha(sampler2D tex, ...).
vec3 slots_at(sampler2D field, vec2 uv) {
	// Outside the field is base ground level, not an occluder.
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
		return vec3(0.0);
	}
	return texture(field, uv).rgb * height_divisor;
}

float sum6(vec3 a, vec3 b) {
	return a.x + a.y + a.z + b.x + b.y + b.z;
}

void fragment() {
	vec3 a0 = slots_at(TEXTURE, UV);
	vec3 b0 = slots_at(field_b, UV) * use_field_b;
	float h0 = sum6(a0, b0);

	float mine = 0.0;       // strongest shadow owned by this slot
	float above = 0.0;      // strongest shadow owned by a higher slot
	float mt_mine = 0.0;    // largest horizon tangent seen for this slot
	float mt_above = 0.0;   // ... and for higher slots
	float crossed = 0.0;    // has this ray entered a blocker strip yet

	// Highest an occluder could possibly stand above this pixel.
	float head_room = max(0.0, max_tiers - h0) * tier_px;

	// GEOMETRIC stride, not uniform. A fixed stride cannot serve both a short
	// shadow and a map-spanning one: sized for the long case it steps straight
	// over occluders and leaves thin unshadowed bands. Stepping finely near the
	// pixel (where the shadow edge is decided) and coarsening with distance
	// (where angles are shallow) covers huge distances at low step counts.
	// Jitter the march's starting offset per pixel. Without this, neighbouring
	// pixels sample the SAME texels at the same distances, so quantisation error
	// correlates across a whole row and reads as hard banding — worst when the sun
	// is near-axis-aligned and the march runs along a texel row. Jittering trades
	// coherent stripes for fine incoherent noise, which the soft shadow hides.
	float jitter = fract(sin(dot(UV * raster_size_px, vec2(12.9898, 78.233))) * 43758.5453);
	float d_px = base_stride_px * jitter;
	float stride = base_stride_px;

	for (int i = 1; i <= MAX_STEPS; i++) {
		if (i > steps) {
			break;
		}
		d_px += stride;
		stride *= stride_growth;

		// Early exit. `cap` is the largest horizon tangent still achievable past
		// this distance, so once it drops below what would be needed to change the
		// result there is nothing left to find.
		//
		// This is layer-aware, and it has to be. The old single-pass version broke
		// as soon as the running maximum could not grow — but with per-layer passes
		// a nearer occluder belonging to a DIFFERENT layer must not terminate our
		// march, or the higher layer loses its shadow entirely (a cliff contour
		// 100px away would end the road-on-the-plateau pass before it ever reached
		// the road 800px away). Hence separate bounds per category:
		//   * `mine` can still grow while cap > max(tan_lo, mt_mine)
		//   * `above` can still grow while cap > max(tan_lo, mt_above)
		//   * and `above` only matters at all while mine > above, since the output
		//     is (mine - above) and is already 0 otherwise.
		float cap = head_room / d_px;
		if (cap <= max(tan_lo, mt_mine)) {
			if (has_above < 0.5) {
				break;
			}
			if (mine <= above) {
				break;
			}
			if (cap <= max(tan_lo, mt_above)) {
				break;
			}
		}

		vec2 uv_s = UV + (sun_dir_px * d_px) / raster_size_px;
		vec3 sa = slots_at(TEXTURE, uv_s);
		vec3 sb = slots_at(field_b, uv_s) * use_field_b;
		float dh = sum6(sa, sb) - h0;

		if (dh > self_bias_tiers) {
			// Which slot owns this obstruction: the HIGHEST one whose own channel
			// rises between here and there. Highest rather than largest, because
			// the sprite has to sit above the artwork of every layer that
			// contributes to the obstruction in order to darken it.
			vec3 ca = sa - a0;
			vec3 cb = sb - b0;
			int win = -1;
			int fallback = -1;
			if (ca.x > 0.00001) { fallback = 0; }
			if (ca.x > attr_bias_tiers) { win = 0; }
			if (ca.y > 0.00001) { fallback = 1; }
			if (ca.y > attr_bias_tiers) { win = 1; }
			if (ca.z > 0.00001) { fallback = 2; }
			if (ca.z > attr_bias_tiers) { win = 2; }
			if (cb.x > 0.00001) { fallback = 3; }
			if (cb.x > attr_bias_tiers) { win = 3; }
			if (cb.y > 0.00001) { fallback = 4; }
			if (cb.y > attr_bias_tiers) { win = 4; }
			if (cb.z > 0.00001) { fallback = 5; }
			if (cb.z > attr_bias_tiers) { win = 5; }
			// The total can clear self_bias_tiers while every individual slot sits
			// under attr_bias_tiers (two layers' blur ramps overlapping). Falling
			// back to the highest slot with ANY rise keeps such an occluder owned
			// by somebody instead of dropping it and punching a hole in the shadow.
			if (win < 0) {
				win = fallback;
			}

			if (win >= group_slot) {
				// Tangent a ray must exceed to clear this obstruction.
				float tan_needed = (dh * tier_px) / d_px;

				// How much shadow THIS occluder casts here. No length or depth
				// fade any more: a real shadow stays equally dark to its end
				// (only the penumbra softens, which the angular band above
				// already provides), and the removed `step_falloff` only read as
				// a fade at low sun anyway — its ramp was normalised by the
				// worst-case reach, so short shadows just darkened uniformly.
				// Removed 2026-08-07 with the user's sign-off, together with the
				// never-exposed `depth_falloff`.
				float s = smoothstep(tan_lo, tan_hi, tan_needed);
				if (s > 0.0) {
					// Opacity is folded in HERE, before the per-slot maxima, so the
					// telescoping subtraction below works on final coverage values.
					float sv = s * clamp(opacity, 0.0, 1.0);
					if (win == group_slot) {
						mine = max(mine, sv);
						mt_mine = max(mt_mine, tan_needed);
					} else {
						above = max(above, sv);
						mt_above = max(mt_above, tan_needed);
					}
				}
			}
		}

		// Blocker: break on EXIT, not on contact. A wall that both casts and
		// blocks is its own blocker — the blocker strip and the elevation
		// strip are the SAME strip, and both have soft edges (FILTER smear vs
		// the level_blend ramp). Breaking on first contact raced those edges:
		// a step could land on the blocker fringe a texel before the
		// elevation ramp cleared self_bias, ending the march before the
		// wall's own height ever registered — the wall's shadow survived only
		// 1-2 squares out (fine strides win the race near the wall) and
		// vanished beyond. Tracking "inside" and breaking on the first sample
		// PAST the strip lets every on-strip sample register elevation while
		// still stopping everything beyond it.
		if (use_blocker > 0.5) {
			if (texture(blocker_tex, uv_s).r > 0.3) {
				crossed = 1.0;
			} else if (crossed > 0.5) {
				break;
			}
		}
	}

	// Emit only the part of this pixel's shadow that no higher layer already
	// draws. Composited multiplicatively with the other layers' sprites this
	// telescopes to max(all slots): the ground darkens once however many layers
	// overlap it, while a layer's own artwork (which hides the sprites below it)
	// still receives everything from above.
	float strength = clamp((mine - above) / max(0.0001, 1.0 - above), 0.0, 1.0);

	// Hide the shadow under this layer's own flagged artwork. Sampled in the same
	// normalised space as the field (the mask raster shares the raster rect).
	if (use_art_mask > 0.5) {
		vec3 mm = texture(art_mask, UV).rgb;
		float m = mask_channel == 0 ? mm.r : (mask_channel == 1 ? mm.g : mm.b);
		strength *= 1.0 - clamp(m, 0.0, 1.0);
	}

	// Strength goes in RED, not ALPHA. Godot 3 GLES3 allocates RGB10_A2 for
	// 2D/disable_3d render targets, so alpha carries only TWO BITS and any
	// gradient written there collapses to {0, 1/3, 2/3, 1}. ShadowDisplay.shader
	// converts red back to a shadow on the visible sprite.
	COLOR = vec4(strength, strength, strength, 1.0);
}
