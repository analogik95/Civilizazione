shader_type spatial;
render_mode cull_disabled, diffuse_burley, depth_draw_always;

// Sea surface, with foam breaking against the shore.
//
// From part 8 of Catlike Coding's hex map series. The idea that makes it work
// is encoding *distance from land* into the mesh rather than computing it in
// the shader: UV.y carries how many tiles of open water lie between this vertex
// and the nearest coast, so the shader gets the one piece of information it
// cannot cheaply derive, and everything else follows from it.
//
// Foam is two sine fronts travelling in opposite directions, combined with max
// rather than added — added waves cancel where they cross and leave holes,
// while max keeps whichever crest is stronger and reads as surf. A square-root
// curve on the shore term concentrates the effect hard against the coast
// instead of fading it evenly out to sea.

uniform sampler2D wave_noise : hint_default_white, repeat_enable, filter_linear;

uniform vec3 shallow_color : source_color = vec3(0.22, 0.60, 0.78);
uniform vec3 deep_color : source_color = vec3(0.06, 0.20, 0.42);
uniform vec3 foam_color : source_color = vec3(0.86, 0.94, 0.99);

// How far out from land, in tiles, foam is still visible.
uniform float foam_reach = 0.45;
uniform float foam_strength = 0.85;
uniform float wave_speed = 0.6;
uniform float wave_scale = 9.0;
uniform float noise_scale = 0.09;

void fragment() {
	// UV.y is distance from land, measured in tiles: negative under the beach,
	// 0 at the waterline, rising out to sea.
	float shore_distance = UV.y;

	// Normalise to the tutorial's convention: 1 at the beach, falling to 0 at
	// the edge of the surf zone.
	//
	// The range has to start at -1, not 0. Corner vertices touching land carry
	// -1 and the tile centre carries 0, so measuring from 0 saturates every
	// vertex from the beach to the middle of the first water tile at full foam
	// — which is what turned the coastline into a solid white halo.
	float w = clamp((foam_reach - shore_distance) / (foam_reach + 1.0), 0.0, 1.0);

	// The square root pulls the surf hard against the coast. Without it the
	// foam fades evenly and reads as a glow rather than breaking water.
	float shore = sqrt(w);

	// World-space noise so the pattern does not swim with the camera or repeat
	// per tile. Distortion weakens toward the beach so the crests follow the
	// coastline instead of cutting across it.
	vec2 world_uv = UV2.xy * noise_scale;
	float noise = texture(wave_noise, world_uv + vec2(TIME * 0.012, 0.0)).r;
	float distortion = noise * (1.0 - shore);

	// Two fronts, one running in and one running out, combined with max —
	// summing them cancels where the crests cross and punches holes in the surf.
	float t = TIME * wave_speed;
	float foam1 = sin((shore + distortion - t) * wave_scale);
	foam1 *= foam1;
	float foam2 = sin((shore + distortion + t) * wave_scale + 3.14159);
	foam2 *= foam2;

	// Multiplying by shore again is what keeps the waterline itself clear: surf
	// peaks just off the beach and dies at it, which is what surf actually does.
	// The old shader instead forced a solid opaque lip along every coast, which
	// is what made the shore read as a white ring drawn around the land.
	// Cubed, so surf is confined to the last stretch before the beach and open
	// water stays open water.
	float foam = max(foam1, foam2) * shore * shore * shore * foam_strength;

	float distance_in = clamp(shore_distance / foam_reach, 0.0, 1.0);

	vec3 water = mix(shallow_color, deep_color, smoothstep(0.0, 3.0, shore_distance));
	vec3 albedo = mix(water, foam_color, clamp(foam, 0.0, 1.0));

	// Pack ice is opaque and still: COLOR.a flags it, COLOR.rgb carries it.
	float ice = COLOR.a;
	albedo = mix(albedo, COLOR.rgb, ice);

	ALBEDO = albedo;
	ROUGHNESS = mix(mix(0.42, 0.08, distance_in), 0.85, ice);
	METALLIC = 0.2 * distance_in * (1.0 - ice);
	SPECULAR = 0.6;
	// Shallows stay slightly translucent so the beach reads through them.
	ALPHA = mix(mix(0.88, 0.97, distance_in), 1.0, ice);
}
