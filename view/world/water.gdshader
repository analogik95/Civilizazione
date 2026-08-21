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
uniform float foam_reach = 0.34;
uniform float wave_speed = 0.35;
uniform float wave_scale = 3.5;
uniform float noise_scale = 0.09;

void fragment() {
	// 0 at the shoreline, rising with distance out to sea.
	float shore = UV.y;

	// World-space sampling so the pattern does not swim when the camera moves
	// and does not repeat per tile.
	vec2 world_uv = vec2(UV2.x, UV2.y) * noise_scale;
	float wobble = texture(wave_noise, world_uv + vec2(TIME * 0.012, 0.0)).r - 0.5;

	float distance_in = clamp(shore / foam_reach, 0.0, 1.0);
	float band = 1.0 - distance_in;

	// Two fronts, one running in and one running out.
	float phase = shore * wave_scale + wobble * 1.6;
	float incoming = sin(phase - TIME * wave_speed * TAU * 0.25);
	float outgoing = sin(phase * 0.72 + TIME * wave_speed * TAU * 0.17);
	float crest = max(incoming, outgoing) * 0.5 + 0.5;

	// Squaring the band keeps surf in the last half-tile before the beach. The
	// tutorial uses sqrt, which widens it instead — right for its scale, where a
	// cell is ten units across and the shore mesh is a dedicated strip, but here
	// it washed two full tiles of open sea white.
	float foam = band * band * crest * 0.8;
	// A solid lip right at the waterline, so the coast always reads as an edge
	// even when the waves are at a trough.
	// A tighter lip right at the waterline so the coast always reads as an edge,
	// but only in the last fraction of a tile — a wider one floods the shelf.
	foam = max(foam, smoothstep(-0.05, -0.45, shore) * 0.62);

	vec3 water = mix(shallow_color, deep_color, smoothstep(0.0, 3.0, shore));
	vec3 albedo = mix(water, foam_color, clamp(foam, 0.0, 1.0));

	// Pack ice is opaque and still: COLOR.a flags it, COLOR.rgb carries it.
	float ice = COLOR.a;
	albedo = mix(albedo, COLOR.rgb, ice);

	ALBEDO = albedo;
	ROUGHNESS = mix(mix(0.55, 0.08, distance_in), 0.85, ice);
	METALLIC = 0.2 * distance_in * (1.0 - ice);
	SPECULAR = 0.6;
	ALPHA = mix(mix(0.97, 0.88, distance_in), 1.0, ice);
}
