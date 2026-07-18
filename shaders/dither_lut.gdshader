shader_type canvas_item;
render_mode unshaded;

// Post-process: an ordered dither down to the palette baked into lut_512.png (the four real
// Game Boy DMG blue-green shades, see tools/gen_gameboy_lut.py).
//
// The dither nudges each pixel by its Bayer threshold and snaps the result to the nearest
// palette entry via a single LUT fetch (a 64x64x64 RGB cube flattened into an 8x8 grid of 64x64
// blue slices), turning the snapping error into a stable pattern instead of flat banding. With
// only four shades the dither is doing real work: it is what fakes the extra greens between the
// four, exactly the way the actual Game Boy screen did.

uniform sampler2D screen_tex : hint_screen_texture, filter_nearest;
// No source_color: the LUT holds raw sRGB bytes and the screen hands us sRGB, so sampling it
// linearly would decode the table out from under itself.
uniform sampler2D lut_tex : filter_nearest, repeat_disable;

uniform float dither_strength : hint_range(0.0, 0.5) = 0.17;
// Game pixels per Bayer cell. The whole viewport is already 640x360 and integer-upscaled to the
// window, so 1 puts one cell on one game pixel.
uniform float pixel_size : hint_range(1.0, 8.0) = 1.0;

const float LUT_SIZE = 64.0;
const float LUT_TILES = 8.0;
const float LUT_WIDTH = 512.0;

// The 4x4 Bayer matrix, built from the 2x2 by recursion rather than looked up. Dynamically
// indexing a const array makes Mesa's V3D compiler emit a deep select chain; this recursion is a
// bit-for-bit identical matrix without it.
float bayer2(vec2 a) { a = floor(a); return fract(a.x / 2.0 + a.y * a.y * 0.75); }
float bayer4(vec2 a) { return bayer2(0.5 * a) * 0.25 + bayer2(a); }

vec3 palette_snap(vec3 c) {
	c = clamp(c, 0.0, 1.0);
	float slice = floor(c.b * (LUT_SIZE - 1.0) + 0.5);
	vec2 tile = vec2(mod(slice, LUT_TILES), floor(slice / LUT_TILES));
	vec2 cell = floor(c.rg * (LUT_SIZE - 1.0) + 0.5);
	// +0.5 lands on the texel centre; filter_nearest still needs us not to sit on a texel
	// boundary, where the rounding could go either way.
	vec2 uv = (tile * LUT_SIZE + cell + 0.5) / LUT_WIDTH;
	return texture(lut_tex, uv).rgb;
}

void fragment() {
	vec3 c = texture(screen_tex, SCREEN_UV).rgb;
	float threshold = bayer4(FRAGCOORD.xy / pixel_size) - 0.5;
	COLOR = vec4(palette_snap(c + threshold * dither_strength), 1.0);
}
