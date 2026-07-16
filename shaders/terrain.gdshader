shader_type spatial;
render_mode diffuse_lambert, specular_disabled, cull_disabled;

// Ground cover for the terrain: which of grass/dirt/rock a facet wears, decided from
// its slope, its height, and whether it falls inside a maintained farmyard plot.
//
// Slope decides the cover on HILLS, not on the farm. The basin is p90 3.7 degrees and
// tops out at 11, so the dirt rule (from 10 degrees) paints ~0% of it — measured, the
// basin's dirt is 7.3% plots and 2.4% hollows, and 0.0% slope. Read literally, "spread
// by slope rules" would give the player a uniform green carpet where they actually
// live, so the plots and the per-face tint are what carry the farm, and they are not
// decoration to be traded away.
//
// UVs are world-space planar XZ. The mesh has no UVs at all and does not need any:
// planar mapping stretches the texture on steep ground, but measured against this
// terrain only 1.6% of visible ground is steeper than 30 degrees, so triplanar would
// triple the sample count to fix a problem 98% of the frame does not have. (That
// statistic is a heightfield measurement and says nothing about skirts, which are
// genuinely vertical walls and do stretch — they are pinhole plugs seen edge-on for a
// few pixels, so it does not matter there either.)
//
// All three textures are sampled unconditionally. Branching to skip one would put a
// texture fetch inside non-uniform control flow, where the implicit derivative -- and
// therefore the mipmap level -- is undefined.
//
// The filter is nearest_mipmap_ANISOTROPIC, and the anisotropic part is load-bearing.
// Ground is only ever seen at a grazing angle, where a pixel's footprint along the view
// direction grows with distance SQUARED while its lateral footprint grows linearly. An
// isotropic sampler takes the larger derivative, so it jumps to a tiny mip long before
// the texture is actually too small sideways -- measured, ground detail (stddev of
// luminance) fell from 6.5 at 6 units to 1.8 by ~40 units, i.e. the texture was gone
// well before fog_depth_begin=200 could hide its absence. Anisotropic sampling restores
// 1.3-1.8x of that detail through the 10-35 unit band, which is most of the screen.
// 'nearest' still governs magnification, so the chunky low-res look up close is intact.
// One array rather than a sampler per ground type: the farm plan chooses a layer with a
// value read from a texture, and a sampler cannot be indexed dynamically. This keeps the
// cost at three samples however many ground types the designer grows.
uniform sampler2DArray ground_tex : filter_nearest_mipmap_anisotropic, repeat_enable;

// World units per texture repeat. Grass and dirt are what you stand on, so their tile
// is sized for the near field (~2 game pixels per texel at 15 units). Rock is only
// ever a distant hillside seen face-on, where a 4-unit repeat tiles a dozen times
// across one slope and reads as woven fabric; a coarser repeat trades chunkier texels
// -- which are sub-pixel at that range anyway -- for far less obvious repetition.
uniform float tile_world_units = 4.0;
uniform float rock_tile_world_units = 11.0;

// Slope cutoffs arrive as cosines so the fragment can compare the face normal's Y
// directly. Storing degrees here would cost an acos per fragment to say the same
// thing; terrain_manager.gd converts from the degree-valued exports once at startup.
uniform float dirt_begin_cos = 0.985;
uniform float dirt_full_cos = 0.951;
uniform float rock_begin_cos = 0.927;
uniform float rock_full_cos = 0.848;

// Hollows go to bare dirt, the way a stock-trampled low spot does.
uniform float water_level = -3.0;

// The farm plan's zone map: one texel per 2-unit cell, holding the ground LAYER to use
// there. filter_nearest is not a style choice — a pen's edge has to be exactly where the
// designer drew it, and a linear fetch would smear two grounds across the boundary.
uniform sampler2D zone_map : filter_nearest, repeat_disable;
uniform float plan_origin = -256.0;
uniform float plan_cell_size = 2.0;
uniform int plan_grid = 256;
uniform bool plan_active = false;

const float LAYER_PASTURE = 0.0;
const float LAYER_DIRT = 1.0;
const float LAYER_ROCK = 4.0;

varying vec3 v_world;
varying vec3 v_world_normal;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize(mat3(MODEL_MATRIX) * NORMAL);
}

// Which ground the farm plan authored here, as a layer index; pasture where the plan is
// absent or silent. Returns -1 in .y when this pixel is outside the plan entirely, which
// is how the rest of the shader knows the terrain's own rules are the whole story here.
//
// texelFetch, not texture(): this read sits behind an early-out, i.e. inside non-uniform
// control flow, where an implicit derivative -- and so the mip level -- is undefined. That
// is the exact rule stated at the top of this file for the ground samples, and a
// texture() here broke it. It happened to be harmless only because zone_map carries no
// mipmaps, so every LOD resolved to base: an accident of the sampler hint, not a
// guarantee, and a real bug the day anyone gives this texture mipmaps.
//
// Fetching by integer cell also removes a genuine off-by-one. A pixel landing exactly on
// the far edge gives uv == 1.0, which passes a `> 1.0` test and then addresses texel 256
// of a 256-wide map -- clamped back to 255, silently wrapping the plan's east edge onto
// its west one.
vec2 planned_ground(vec2 world_xz) {
	ivec2 cell = ivec2(floor((world_xz - vec2(plan_origin)) / plan_cell_size));
	if (!plan_active || any(lessThan(cell, ivec2(0))) || any(greaterThanEqual(cell, ivec2(plan_grid)))) {
		return vec2(LAYER_PASTURE, -1.0);
	}
	// R8 arrives normalised; scale back to the integer the designer wrote.
	float layer = floor(texelFetch(zone_map, cell, 0).r * 255.0 + 0.5);
	return vec2(layer, 1.0);
}

void fragment() {
	vec2 uv = v_world.xz / tile_world_units;

	// The plan overrides the BASE ground only. Slope still gets a say on top, so a road
	// climbing a bank still washes into dirt and rock the way the bank does.
	vec2 planned = planned_ground(v_world.xz);
	vec3 base = texture(ground_tex, vec3(uv, planned.x)).rgb;
	vec3 dirt = texture(ground_tex, vec3(uv, LAYER_DIRT)).rgb;
	vec3 rock = texture(ground_tex, vec3(v_world.xz / rock_tile_world_units, LAYER_ROCK)).rgb;

	// Face normals (vertices are not shared), so slope is per-facet and the cover
	// changes on facet boundaries -- which is the low-poly look, not an artifact.
	float up = clamp(v_world_normal.y, 0.0, 1.0);
	float to_dirt = 1.0 - smoothstep(dirt_full_cos, dirt_begin_cos, up);
	float to_rock = 1.0 - smoothstep(rock_full_cos, rock_begin_cos, up);

	float hollow = 1.0 - smoothstep(water_level, water_level + 3.0, v_world.y);
	to_dirt = max(to_dirt, hollow);

	// Authored ground already IS its material, so do not smear dirt over a road or a
	// crop just because the basin dips a little, and never put bare rock on one. A
	// painted PASTURE is exempt: it is asking for grass, and grass is what the slope
	// rules are for, so it keeps them.
	float authored = step(0.0, planned.y) * step(0.5, abs(planned.x - LAYER_PASTURE));
	to_dirt *= 1.0 - authored;
	to_rock *= 1.0 - authored;

	vec3 albedo = mix(base, dirt, to_dirt);
	albedo = mix(albedo, rock, to_rock);

	// COLOR is a large-scale tint baked per face by terrain_manager.gd, centred near
	// white. It is what stops a 4-unit texture repeat reading as a grid across the
	// basin, and it costs nothing per fragment because the mesh already carried a
	// colour array.
	ALBEDO = albedo * COLOR.rgb;
	ROUGHNESS = 1.0;
}
