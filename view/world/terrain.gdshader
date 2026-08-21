shader_type spatial;
render_mode cull_back, diffuse_burley, specular_disabled;

// Ground shading for the continuous terrain mesh.
//
// The mesh gives every vertex a base colour, but a 4X tile is two world units
// across and vertices are sparse, so flat vertex colour makes each hex read as
// a solid patch — a grid, which is exactly what Civilization VI's terrain does
// not look like. Civ 6's ground is an organic field: colour varies *within* a
// tile and across tile boundaries alike, and the hex grid is implied only by
// borders and by what is built on the land.
//
// So the vertex colour sets the biome and this shader breaks it up. Noise is
// sampled in world space rather than from UVs, which means it ignores tile
// boundaries completely and never seams — the whole point.

uniform sampler2D noise_texture : hint_default_white, repeat_enable, filter_linear;

// Two octaves at different scales. The coarse one gives regional variation —
// patches larger than a tile, so terrain does not look uniform across a
// continent. The fine one gives close-up texture.
uniform float coarse_scale = 0.035;
uniform float coarse_strength = 0.16;
uniform float fine_scale = 0.34;
uniform float fine_strength = 0.09;

// Slopes darken slightly, which is what makes gentle relief legible on ground
// that is otherwise one flat colour.
uniform float slope_shading = 0.22;

uniform float roughness_value = 0.95;

varying vec3 world_position;
varying vec3 world_normal;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	float coarse = texture(noise_texture, world_position.xz * coarse_scale).r;
	float fine = texture(noise_texture, world_position.xz * fine_scale).r;

	// Centre both octaves on zero so they lighten and darken equally rather
	// than only ever brightening the base colour.
	float variation =
		(coarse - 0.5) * 2.0 * coarse_strength +
		(fine - 0.5) * 2.0 * fine_strength;

	// A face pointing straight up gets no slope shading; anything tilted gets
	// progressively more.
	float flatness = clamp(world_normal.y, 0.0, 1.0);
	float slope = (1.0 - flatness) * slope_shading;

	vec3 albedo = COLOR.rgb * (1.0 + variation) * (1.0 - slope);

	ALBEDO = clamp(albedo, vec3(0.0), vec3(1.0));
	ROUGHNESS = roughness_value;
	SPECULAR = 0.0;
}
