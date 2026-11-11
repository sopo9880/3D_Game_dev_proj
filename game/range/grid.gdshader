shader_type spatial;
// 월드 좌표 기준 격자. 거리와 속도를 눈으로 가늠하기 위한 임시 바닥·벽 재질.
uniform vec3 base_color : source_color = vec3(0.34, 0.42, 0.36);
uniform vec3 line_color : source_color = vec3(0.22, 0.28, 0.24);
uniform float cell = 1.0;

varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

float grid(vec2 p, float size) {
	vec2 g = abs(fract(p / size - 0.5) - 0.5) / fwidth(p / size);
	return 1.0 - clamp(min(g.x, g.y), 0.0, 1.0);
}

void fragment() {
	vec3 n = abs(world_normal);
	vec2 p = n.y > 0.5 ? world_pos.xz : (n.x > 0.5 ? world_pos.zy : world_pos.xy);
	float fine = grid(p, cell) * 0.6;
	float coarse = grid(p, cell * 5.0);
	ALBEDO = mix(base_color, line_color, max(fine, coarse));
	ROUGHNESS = 0.9;
}
