shader_type canvas_item;
render_mode unshaded;

// Post-process: a heavy toon edge outline, then an ordered dither down to the palette baked
// into lut_512.png (now a 16-shade monochrome Game Boy green ramp, see tools/gen_gameboy_lut.py).
//
// The outline is a screen-space Sobel edge detector run on the scene's luminance: wherever the
// image steps sharply — a silhouette against the sky, a crease between two flat-shaded facets —
// the pixel is pushed to the outline colour before the palette snap, so every object in the
// frame gets a bold dark border without touching any of its material. It is a "pseudo" toon
// pass: it reads geometry from the rendered picture rather than from depth/normals (which the
// Compatibility renderer does not hand a 2D shader), which is exactly what makes it apply to
// everything on screen at once.
//
// The dither then nudges each pixel by its Bayer threshold and snaps the result to the nearest
// palette entry via a single LUT fetch (a 64x64x64 RGB cube flattened into an 8x8 grid of 64x64
// blue slices), turning the snapping error into a stable pattern instead of flat banding.

uniform sampler2D screen_tex : hint_screen_texture, filter_nearest;
// No source_color: the LUT holds raw sRGB bytes and the screen hands us sRGB, so sampling it
// linearly would decode the table out from under itself.
uniform sampler2D lut_tex : filter_nearest, repeat_disable;

uniform float dither_strength : hint_range(0.0, 0.5) = 0.09;
// Game pixels per Bayer cell. The whole viewport is already 640x360 and integer-upscaled to the
// window, so 1 puts one cell on one game pixel.
uniform float pixel_size : hint_range(1.0, 8.0) = 1.0;

// ---- outline ----------------------------------------------------------------
// How hard the edge is drawn (1 = fully replaced with the outline colour).
uniform float outline_strength : hint_range(0.0, 1.0) = 1.0;
// Sobel magnitude an edge must clear to start drawing, and the soft ramp above it. Lower =
// more edges (creases as well as silhouettes); higher = only the strong borders.
uniform float outline_threshold : hint_range(0.0, 1.0) = 0.18;
uniform float outline_softness : hint_range(0.0, 0.5) = 0.05;
// Sample spread in screen pixels — how thick the border reads.
uniform float outline_width : hint_range(0.5, 4.0) = 0.9;
// Where an edge pixel is pushed before the palette snap (a near-black green so it lands on the
// darkest Game Boy shade).
uniform vec3 outline_color : source_color = vec3(0.02, 0.05, 0.03);

const float LUT_SIZE = 64.0;
const float LUT_TILES = 8.0;
const float LUT_WIDTH = 512.0;

// The 8x8 Bayer matrix, generated rather than looked up. Dynamically indexing a const array
// makes Mesa's V3D compiler emit a 64-deep select chain, which measured 0.49ms/frame slower
// than this recursion for a bit-for-bit identical matrix.
float bayer2(vec2 a) { a = floor(a); return fract(a.x / 2.0 + a.y * a.y * 0.75); }
float bayer4(vec2 a) { return bayer2(0.5 * a) * 0.25 + bayer2(a); }
float bayer8(vec2 a) { return bayer4(0.5 * a) * 0.25 + bayer2(a); }

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

float luma(vec2 uv) {
	return dot(texture(screen_tex, uv).rgb, vec3(0.299, 0.587, 0.114));
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec3 c = texture(screen_tex, uv).rgb;

	// Sobel edge detect on luminance -> a heavy dark outline on everything in the frame.
	vec2 px = SCREEN_PIXEL_SIZE * outline_width;
	float tl = luma(uv + px * vec2(-1.0, -1.0));
	float tc = luma(uv + px * vec2( 0.0, -1.0));
	float tr = luma(uv + px * vec2( 1.0, -1.0));
	float ml = luma(uv + px * vec2(-1.0,  0.0));
	float mr = luma(uv + px * vec2( 1.0,  0.0));
	float bl = luma(uv + px * vec2(-1.0,  1.0));
	float bc = luma(uv + px * vec2( 0.0,  1.0));
	float br = luma(uv + px * vec2( 1.0,  1.0));
	float gx = -tl - 2.0 * ml - bl + tr + 2.0 * mr + br;
	float gy = -tl - 2.0 * tc - tr + bl + 2.0 * bc + br;
	float edge = sqrt(gx * gx + gy * gy);
	float e = smoothstep(outline_threshold, outline_threshold + outline_softness, edge) * outline_strength;
	c = mix(c, outline_color, e);

	float threshold = bayer8(FRAGCOORD.xy / pixel_size) - 0.5;
	COLOR = vec4(palette_snap(c + threshold * dither_strength), 1.0);
}
