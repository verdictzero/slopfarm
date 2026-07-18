shader_type canvas_item;
render_mode unshaded;

// Post-process: the world redrawn as an old dot-matrix LCD in the 16 Game Boy greens baked into
// lut_512.png -- the SAME pea-green ramp the menu chrome is tokened in (see
// tools/gen_menu_palette_lut.py), so the dithered world and the UI are one screen.
//
// Three things happen here, in order:
//   1. Pseudo pixels. The native buffer is diced into a hard grid of grid_size x grid_size cells.
//      Each cell samples the world ONCE, at its centre, so a whole cell carries one colour -- the
//      chunky "LCD dot" the real hardware had, independent of how far the buffer is upscaled after.
//   2. Ordered dither + palette snap. Each cell is nudged by its Bayer threshold and snapped to the
//      nearest of the 16 greens via one LUT fetch (a 64x64x64 RGB cube flattened into an 8x8 grid
//      of 64x64 blue slices). The dither is keyed to the CELL, not the native pixel, so the pattern
//      lives at dot resolution and fakes the shades between the 16 the way a DMG screen did.
//   3. Hard grid. The leading edge of every cell is darkened toward the palette's darkest green,
//      drawing the unlit lattice between dots -- the gap you see on an actual LCD.

uniform sampler2D screen_tex : hint_screen_texture, filter_nearest;
// No source_color: the LUT holds raw sRGB bytes and the screen hands us sRGB, so sampling it
// linearly would decode the table out from under itself.
uniform sampler2D lut_tex : filter_nearest, repeat_disable;

uniform float dither_strength : hint_range(0.0, 0.5) = 0.17;
// Native buffer pixels per LCD dot. The world SubViewport is 360x360 and integer-upscaled to the
// window, so 3 makes each dot a 3x3 block of native pixels (a 120x120 dot grid). >= 2 to leave
// room for the lattice line; 1 collapses back to a per-pixel dither with no grid.
uniform float grid_size : hint_range(1.0, 8.0) = 3.0;
// Width, in native pixels, of the dark lattice line drawn along each dot's leading edges.
uniform float grid_gap : hint_range(0.0, 3.0) = 1.0;
// How far the lattice line is dropped down the green ramp: 0 no grid, 1 pushes the gap all the
// way to the darkest green. The drop is re-snapped, so gap pixels are still palette greens.
uniform float grid_strength : hint_range(0.0, 1.0) = 0.45;

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
	// Which LCD dot this native pixel belongs to, and where it sits inside that dot.
	vec2 cell = floor(FRAGCOORD.xy / grid_size);
	vec2 local = FRAGCOORD.xy - cell * grid_size;

	// One sample per dot, taken at the dot centre, so the whole cell is a single flat colour.
	vec2 sample_uv = (cell + 0.5) * grid_size * SCREEN_PIXEL_SIZE;
	vec3 c = texture(screen_tex, sample_uv).rgb;

	// Dither keyed to the dot, not the pixel, then snap to the 16 greens.
	float threshold = bayer4(cell) - 0.5;
	vec3 dot = palette_snap(c + threshold * dither_strength);

	// Hard lattice: the leading edge of each dot drops down the green ramp and re-snaps, so the
	// gap between dots is itself a (darker) palette green -- the whole frame stays inside the 16.
	// In lit areas this draws the dark grid; over already-dark dots it snaps back to the same
	// shade and vanishes, exactly like the unlit gaps on a real reflective LCD.
	float on_grid = (grid_size > 1.5 && (local.x < grid_gap || local.y < grid_gap)) ? 1.0 : 0.0;
	dot = mix(dot, palette_snap(dot * (1.0 - grid_strength)), on_grid);

	COLOR = vec4(dot, 1.0);
}
