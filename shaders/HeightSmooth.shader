shader_type canvas_item;

// One axis of a SEPARABLE blur over the elevation field. Run twice — once
// horizontally, once vertically — for a 2D Gaussian at a fraction of the cost.
//
// Why separable rather than a single NxN kernel: the previous version kept a
// fixed 7x7 tap count and scaled the tap SPACING by the radius. That is not a
// blur, it is a sparse point sample — push the radius past the tap count and it
// aliases, which brought back the exact sun-direction streaking the smoothing
// exists to remove. Here the spacing is always one texel and only the tap COUNT
// grows, so widening the blur can never undersample.
//
// The smoothing itself is mandatory: contour polygons rasterise with hard edges,
// so a diagonal contour becomes a staircase whose every step casts its own long
// thin shadow. It also erases one-texel slivers where overlapping contour
// polygons add their heights together.

uniform vec2 direction = vec2(1.0, 0.0);   // (1,0) horizontal pass, (0,1) vertical
uniform vec2 texel_size = vec2(0.0005, 0.0005);
uniform int taps = 4;                      // half-width, in texels
uniform float sigma = 2.0;

const int MAX_TAPS = 24;

// All THREE channels, not just red: each colour channel carries one caster
// layer's own elevation contribution (see HeightField.gd's SLOTS notes), and the
// march needs every one of them blurred identically. Blur is linear, so blurring
// the channels separately and summing them in the march is the same as blurring
// the summed height — which is what makes the packing free.
vec3 sample_height(sampler2D field, vec2 uv) {
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
		return vec3(0.0);
	}
	return texture(field, uv).rgb;
}

void fragment() {
	vec2 step_uv = direction * texel_size;
	float inv = 1.0 / (2.0 * max(0.35, sigma) * max(0.35, sigma));

	vec3 total = sample_height(TEXTURE, UV);
	float weight_sum = 1.0;

	for (int i = 1; i <= MAX_TAPS; i++) {
		if (i > taps) {
			break;
		}
		float w = exp(-float(i * i) * inv);
		vec2 o = step_uv * float(i);
		total += sample_height(TEXTURE, UV + o) * w;
		total += sample_height(TEXTURE, UV - o) * w;
		weight_sum += 2.0 * w;
	}

	// One layer per channel; alpha is opaque so the march never sees a hole.
	COLOR = vec4(total / weight_sum, 1.0);
}
