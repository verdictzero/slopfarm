shader_type canvas_item;
render_mode unshaded;

// Post-process: the world redrawn in the 64 Game Boy greens baked into lut_512.png -- the SAME
// pea-green ramp the menu chrome is tokened in (see tools/gen_menu_palette_lut.py), so the dithered
// world and the UI are one screen.
//
// Two things happen here, in order:
//   1. Pseudo pixels. The buffer is diced into a grid of grid_size x grid_size cells. Each cell
//      samples the world ONCE, at its centre, so a whole cell carries one colour -- the "LCD dot",
//      at 1/grid_size the buffer resolution and independent of how far it is scaled up afterward.
//   2. Ordered dither + palette snap. Each cell is nudged by its Bayer threshold and snapped to the
//      nearest of the 64 greens via one LUT fetch (a 64x64x64 RGB cube flattened into an 8x8 grid
//      of 64x64 blue slices). The dither is keyed to the CELL, not the native pixel, so the pattern
//      lives at dot resolution and fakes the shades between the 64 the way a DMG screen did.

uniform sampler2D screen_tex : hint_screen_texture, filter_nearest;
// No source_color: the LUT holds raw sRGB bytes and the screen hands us sRGB, so sampling it
// linearly would decode the table out from under itself.
uniform sampler2D lut_tex : filter_nearest, repeat_disable;

uniform float dither_strength : hint_range(0.0, 0.5) = 0.17;
// Native buffer pixels per LCD dot. The world SubViewport is 1080x1080, so 3 makes each dot a 3x3
// block of native pixels (a 360x360 dot grid); 1 collapses to a full-resolution per-pixel dither.
uniform float grid_size : hint_range(1.0, 8.0) = 3.0;

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
	// One sample per LCD dot, taken at the dot centre, so the whole cell is a single flat colour.
	vec2 cell = floor(FRAGCOORD.xy / grid_size);
	vec2 sample_uv = (cell + 0.5) * grid_size * SCREEN_PIXEL_SIZE;
	vec3 c = texture(screen_tex, sample_uv).rgb;

	// Dither keyed to the dot, not the pixel, then snap to the 64 greens.
	float threshold = bayer4(cell) - 0.5;
	COLOR = vec4(palette_snap(c + threshold * dither_strength), 1.0);
}
