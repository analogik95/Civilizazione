shader_type spatial;
render_mode cull_disabled, diffuse_burley;

// Flowing water for rivers.
//
// Civilization VI puts rivers on tile *edges* rather than through tile centres,
// so the geometry here is a ribbon laid along the shared edge between two hexes
// rather than a channel carved through a cell — which is what Catlike Coding's
// series builds. What ports across from that series is the important part: the
// river is its own mesh with its own material, carrying UV coordinates that let
// a shader animate flow, so the terrain stays completely static while the water
// moves.
//
// U runs across the ribbon (0 at one bank, 1 at the other) and V runs along it.
// Scrolling two noise samples along V at different rates and combining them
// gives motion that never visibly repeats, and the across-channel U drives the
// pale bank shading.

uniform sampler2D flow_noise : hint_default_white, repeat_enable, filter_linear;

uniform vec3 water_shallow : source_color = vec3(0.42, 0.76, 0.94);
uniform vec3 water_deep : source_color = vec3(0.12, 0.42, 0.74);
uniform vec3 bank_color : source_color = vec3(0.86, 0.94, 0.98);

uniform float flow_speed = 0.22;
uniform float noise_scale = 2.4;
uniform float bank_width = 0.26;

void vertex() {
	// Nothing to displace: the ribbon is already sitting on perturbed terrain.
}

void fragment() {
	float across = UV.x;
	float along = UV.y;

	// Two layers moving at different speeds, so the pattern does not tile
	// visibly along a long river.
	float a = texture(flow_noise, vec2(across * noise_scale, along * noise_scale - TIME * flow_speed)).r;
	float b = texture(flow_noise, vec2(across * noise_scale * 1.7 + 0.35, along * noise_scale * 0.6 - TIME * flow_speed * 0.55)).r;
	float ripple = mix(a, b, 0.5);

	// Distance from the nearer bank, 0 at the edge and 1 mid-channel.
	float centre = 1.0 - abs(across * 2.0 - 1.0);

	vec3 water = mix(water_shallow, water_deep, smoothstep(0.0, 0.75, centre) * (0.65 + ripple * 0.5));

	// Pale banks, as in the reference: a river reads as a ribbon because its
	// edges are lighter than the water and the land alike.
	float bank = 1.0 - smoothstep(0.0, bank_width, centre);
	vec3 albedo = mix(water, bank_color, bank);

	ALBEDO = albedo;
	ROUGHNESS = mix(0.55, 0.12, centre);
	METALLIC = 0.15 * centre;
	SPECULAR = 0.5;
	ALPHA = mix(0.85, 1.0, bank);
}
