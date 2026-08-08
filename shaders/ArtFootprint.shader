shader_type canvas_item;
render_mode blend_add;

// ART-FOOTPRINT ELEVATION — raise the ground under a contour path's OWN ARTWORK
// to that path's height, so the elevation step ends at the texture's opaque
// edge instead of on the drawn centreline.
//
// WHY THIS EXISTS. A contour's fill polygon is built from the SPINE, but the
// art is a Line2D that STRADDLES that spine. So the outer half of every cliff
// texture stood over ground the field still called low, and a tall column
// overhead re-qualified as an occluder there: a higher layer's shadow crossed
// the lower cliff's art and landed ON it as a hard line, instead of staying
// tucked under the art until the texture's own alpha edge. Raising that ground
// removes the CONDITION; the march is untouched.
//
// BINARY, NOT ALPHA-WEIGHTED. `alpha_threshold` is the user's rule: only where
// the texture is fully opaque does ground rise, and it rises to the path's FULL
// height. Weighting height by alpha (the first attempt) turned every soft
// texture edge into a partial-height ramp — small elevation steps with no
// artwork over them, which cast their own short shadows in whatever direction
// the local slope faced. That is the "some shadows spawn from the wrong side"
// artefact. There is no partial ground here: a texel is at the path's height or
// at nothing.
//
// NOTHING SELECTS A SIDE, AND NOTHING SUBTRACTS. This target is NOT the fill
// raster. It is combined into the field with max() in the first blur pass, so a
// footprint texel that lands on its own fill, or on a neighbour's, simply loses
// to whichever is taller. The two earlier builds both existed to keep this
// strip off the fill — one by voting which half of the art was "outer" (wrong
// on 22-30% of segments, and each wrong segment built a doubled-height ridge
// whose far edge cast backwards), one by subtracting the fill in Clipper (which
// pulled the footprint off the art it was supposed to follow). Neither problem
// exists once the combine is a max.
//
// Godot 3 trap (see HANDOFF §4): touching COLOR in a canvas_item fragment
// compiles out the automatic texture multiply, so TEXTURE must be sampled here
// explicitly — reading COLOR alone would yield a solid alpha-1 band with no
// texture shape at all.
//
// `use_texture` is 0 when the Line2D has no texture, or draws with
// texture_mode = None (LineBuilder emits no UVs at all in that mode). There is
// no art alpha to follow, and what DD draws is a solid line of full width, so
// the whole strip raises ground.

uniform vec3 channel = vec3(1.0, 0.0, 0.0);   // this layer slot's colour channel
uniform float elevation = 0.0;                // tiers / HEIGHT_DIVISOR
uniform float alpha_threshold = 0.95;         // "100% opacity", minification-tolerant
uniform float use_texture = 1.0;              // 0 = no usable texture, raise all of it

void fragment() {
	float a = 1.0;
	if (use_texture > 0.5) {
		a = texture(TEXTURE, UV).a;
	}
	// step(): fully opaque or nothing. No ramp, ever.
	float on = step(alpha_threshold, a);
	// Alpha 1 so blend_add's src-alpha factor contributes channel*elevation once.
	COLOR = vec4(channel * elevation * on, 1.0);
}
