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
uniform float coarse_strength = 0.085;
// A middle octave at roughly tile scale. Without it the ground had regional
// drift and fine grain but nothing in between, so the eye read the space
// between the two as flat.
uniform float medium_scale = 0.13;
uniform float medium_strength = 0.070;
uniform float fine_scale = 0.34;
uniform float fine_strength = 0.045;

// Ground colour drifts in hue as well as brightness. Real terrain is not one
// green at several exposures; it goes yellow where it is dry and blue-green
// where it is shaded, and mimicking that is most of what separates painted
// ground from flat fill.
uniform vec3 warm_tint = vec3(0.06, 0.03, -0.04);
uniform float tint_strength = 0.32;

// Slopes darken very slightly. This used to carry most of the relief, back when
// the scene had no Environment resource and therefore almost no real lighting —
// with a sky, ambient and a shadowed sun doing that job properly, the same
// value darkens every mountain face twice and turns ranges into black cutouts.
uniform float slope_shading = 0.10;

uniform float roughness_value = 0.95;

varying vec3 world_position;
varying vec3 world_normal;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	float coarse = texture(noise_texture, world_position.xz * coarse_scale).r;
	float medium = texture(noise_texture, world_position.xz * medium_scale + 0.37).r;
	float fine = texture(noise_texture, world_position.xz * fine_scale).r;

	// Centre every octave on zero so they lighten and darken equally rather
	// than only ever brightening the base colour.
	float variation =
		(coarse - 0.5) * 2.0 * coarse_strength +
		(medium - 0.5) * 2.0 * medium_strength +
		(fine - 0.5) * 2.0 * fine_strength;

	// A face pointing straight up gets no slope shading; anything tilted gets
	// progressively more.
	float flatness = clamp(world_normal.y, 0.0, 1.0);
	float slope = (1.0 - flatness) * slope_shading;

	// Warm where the coarse octave is high, cool where it is low. Scaled by how
	// saturated the ground already is, so grey rock and white snow stay neutral
	// instead of picking up a green cast.
	float saturation = max(max(COLOR.r, COLOR.g), COLOR.b) - min(min(COLOR.r, COLOR.g), COLOR.b);
	vec3 tint = warm_tint * ((coarse - 0.5) * 2.0) * tint_strength * saturation * 2.5;

	vec3 albedo = (COLOR.rgb + tint) * (1.0 + variation) * (1.0 - slope);

	ALBEDO = clamp(albedo, vec3(0.0), vec3(1.0));
	ROUGHNESS = roughness_value;
	SPECULAR = 0.0;
}
