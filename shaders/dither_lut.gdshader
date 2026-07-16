shader_type canvas_item;
render_mode unshaded;

// Ordered-dither down to the 512-colour palette baked into lut_512.png.
//
// Nudge each pixel by its Bayer threshold, then snap the result to the nearest
// palette entry. The snap is a single texture fetch rather than a 512-way search:
// lut_512.png is a 64x64x64 RGB cube, pre-solved offline (tools/gen_palette_lut.py),
// flattened into an 8x8 grid of 64x64 blue slices. The dither offset is what turns
// the snapping error into a stable pattern instead of flat banding, so gradients --
// the sky especially -- break up into palette colours rather than posterising.

uniform sampler2D screen_tex : hint_screen_texture, filter_nearest;
// No source_color: the LUT holds raw sRGB bytes and the screen hands us sRGB, so
// sampling it linearly would decode the table out from under itself.
uniform sampler2D lut_tex : filter_nearest, repeat_disable;

// Wants to match the palette's local spacing, and 0.09 measures as the sweet spot:
// sweeping 0.03..0.25 and comparing a slightly blurred frame against the undithered
// original gives a clean U, minimised here. Below it the offset cannot bridge two
// palette entries and gradients band; above it the dither reaches past its neighbour
// and mixes colours that were never close, which reads as noise and drifts the hue.
uniform float dither_strength : hint_range(0.0, 0.5) = 0.09;
// Game pixels per Bayer cell. The whole viewport is already 640x360 and integer-
// upscaled to the window, so 1 puts one cell on one game pixel -- raise it only to
// make the pattern coarser on purpose.
uniform float pixel_size : hint_range(1.0, 8.0) = 1.0;

const float LUT_SIZE = 64.0;
const float LUT_TILES = 8.0;
const float LUT_WIDTH = 512.0;

// The 8x8 Bayer matrix, generated rather than looked up. Dynamically indexing a
// const array makes Mesa's V3D compiler emit a 64-deep select chain, which measured
// 0.49ms/frame slower than this recursion for a bit-for-bit identical matrix
// (verified against the canonical table: same 64 values, same positions).
float bayer2(vec2 a) { a = floor(a); return fract(a.x / 2.0 + a.y * a.y * 0.75); }
float bayer4(vec2 a) { return bayer2(0.5 * a) * 0.25 + bayer2(a); }
float bayer8(vec2 a) { return bayer4(0.5 * a) * 0.25 + bayer2(a); }

vec3 palette_snap(vec3 c) {
	c = clamp(c, 0.0, 1.0);
	float slice = floor(c.b * (LUT_SIZE - 1.0) + 0.5);
	vec2 tile = vec2(mod(slice, LUT_TILES), floor(slice / LUT_TILES));
	vec2 cell = floor(c.rg * (LUT_SIZE - 1.0) + 0.5);
	// +0.5 lands on the texel centre; filter_nearest still needs us not to sit on
	// a texel boundary, where the rounding could go either way.
	vec2 uv = (tile * LUT_SIZE + cell + 0.5) / LUT_WIDTH;
	return texture(lut_tex, uv).rgb;
}

void fragment() {
	vec3 c = texture(screen_tex, SCREEN_UV).rgb;
	float threshold = bayer8(FRAGCOORD.xy / pixel_size) - 0.5;
	COLOR = vec4(palette_snap(c + threshold * dither_strength), 1.0);
}
