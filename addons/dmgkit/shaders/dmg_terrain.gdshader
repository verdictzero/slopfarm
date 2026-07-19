shader_type spatial;
render_mode diffuse_lambert, specular_disabled, cull_disabled;

// dmgkit generic ground cover: which of grass / dirt / rock a facet wears, decided from its
// slope and height. This is the slopfarm terrain shader with the game-specific "farm plan" zone
// overlay (authored plots, roads, crops, trampled mud) stripped out, so it drops into any project.
// DmgTerrainTextures still builds a six-layer atlas (grass, dirt, road, crop, mud, rock) if you
// want to extend this with your own zone logic; the default cover below uses grass/dirt/rock.
//
// UVs are world-space planar XZ — the mesh carries none. The face normal (vertices are not shared,
// so it is per-facet) drives the slope blend, which is what gives the crisp low-poly banding. The
// per-face COLOR is a large-scale tint DmgTerrain bakes in to hide the texture tiling.
//
// All layers are sampled unconditionally: a texture fetch inside non-uniform control flow has an
// undefined derivative (and therefore mip level). One Texture2DArray, filter
// nearest_mipmap_anisotropic — 'nearest' keeps the chunky magnified look, the mipmaps+anisotropy
// stop distant ground aliasing into crawling noise at grazing angles.
uniform sampler2DArray ground_tex : filter_nearest_mipmap_anisotropic, repeat_enable;

// World units per texture repeat. Grass/dirt are sized for the near field; rock is coarser because
// it is only ever a distant hillside seen near face-on, where a fine repeat reads as woven fabric.
uniform float tile_world_units = 4.0;
uniform float rock_tile_world_units = 11.0;

// Slope cutoffs arrive as cosines so the fragment compares the face normal's Y directly (no acos
// per pixel). DmgTerrain converts its degree-valued exports once at startup.
uniform float dirt_begin_cos = 0.985;
uniform float dirt_full_cos = 0.951;
uniform float rock_begin_cos = 0.927;
uniform float rock_full_cos = 0.848;

// Ground at or below this goes to bare dirt — hollows read as trampled/washed low spots.
uniform float water_level = -3.0;

// Atlas layer indices (see DmgTerrainTextures). The default cover only reads these three.
const float LAYER_GRASS = 0.0;
const float LAYER_DIRT = 1.0;
const float LAYER_ROCK = 5.0;

varying vec3 v_world;
varying vec3 v_world_normal;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize(mat3(MODEL_MATRIX) * NORMAL);
}

void fragment() {
	vec2 uv = v_world.xz / tile_world_units;

	vec3 grass = texture(ground_tex, vec3(uv, LAYER_GRASS)).rgb;
	vec3 dirt = texture(ground_tex, vec3(uv, LAYER_DIRT)).rgb;
	vec3 rock = texture(ground_tex, vec3(v_world.xz / rock_tile_world_units, LAYER_ROCK)).rgb;

	// Face normals give per-facet slope, so the cover changes on facet boundaries — the low-poly
	// look, not an artifact.
	float up = clamp(v_world_normal.y, 0.0, 1.0);
	float to_dirt = 1.0 - smoothstep(dirt_full_cos, dirt_begin_cos, up);
	float to_rock = 1.0 - smoothstep(rock_full_cos, rock_begin_cos, up);

	// Hollows wash out to bare dirt.
	float hollow = 1.0 - smoothstep(water_level, water_level + 3.0, v_world.y);
	to_dirt = max(to_dirt, hollow);

	vec3 albedo = mix(grass, dirt, to_dirt);
	albedo = mix(albedo, rock, to_rock);

	// COLOR is the large-scale per-face tint baked by DmgTerrain, centred near white — it is what
	// stops the texture repeat reading as a grid, and costs nothing (the mesh already carries it).
	ALBEDO = albedo * COLOR.rgb;
	ROUGHNESS = 1.0;
}
